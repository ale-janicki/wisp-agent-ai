import XCTest
@testable import WispCore

final class MeetingLinksTests: XCTestCase {
    private func provider(_ text: String) -> MeetingProvider? { MeetingLinks.links(in: text).first?.provider }

    func testProviders() {
        XCTAssertEqual(provider("https://meet.google.com/abc-defg-hij"), .meet)
        XCTAssertEqual(provider("https://us02web.zoom.us/j/123456789?pwd=abc"), .zoom)
        XCTAssertEqual(provider("https://zoom.us/my/someone"), .zoom)
        XCTAssertEqual(provider("zoommtg://zoom.us/join?confno=123"), .zoom)
        XCTAssertEqual(provider("https://teams.microsoft.com/l/meetup-join/19%3ameeting_x/0?context=y"), .teams)
        XCTAssertEqual(provider("https://teams.live.com/meet/9300"), .teams)
        XCTAssertEqual(provider("https://acme.webex.com/meet/jdoe"), .webex)
        XCTAssertEqual(provider("https://app.slack.com/huddle/T123/C456"), .slack)
        XCTAssertEqual(provider("https://facetime.apple.com/join#v=1&p=abc"), .facetime)
    }

    func testNonMeetingUrlsAreIgnored() {
        XCTAssertNil(provider("https://example.com/zoom.us/j/1"))
        XCTAssertNil(provider("https://meet.google.com/"))
        XCTAssertNil(provider("https://www.google.com/search?q=meet.google.com/abc"))
        XCTAssertNil(provider("https://zoom.us/pricing"))
        XCTAssertNil(provider("https://teams.microsoft.com/"))
        XCTAssertNil(provider("https://slack.com/intl/pt-br"))
        XCTAssertNil(provider("javascript://meet.google.com/x"))
        XCTAssertNil(provider("sem link nenhum"))
        XCTAssertNil(provider("evilzoom.us/j/12"))
        XCTAssertNil(provider("https://notzoom.us/j/12"))
    }

    func testLinkInsideProse() {
        let found = MeetingLinks.links(in: "Entre em (https://meet.google.com/abc-defg-hij), às 10h. Ou https://zoom.us/j/99.")
        XCTAssertEqual(found.map(\.url.absoluteString), ["https://meet.google.com/abc-defg-hij", "https://zoom.us/j/99"])
    }

    func testDetectPrefersUrlThenLocationThenNotes() {
        let url = URL(string: "https://meet.google.com/aaa-bbbb-ccc")
        let all = MeetingLinks.detect(url: url, location: "https://zoom.us/j/1", notes: "https://teams.live.com/meet/1")
        XCTAssertEqual(all?.provider, .meet)
        XCTAssertEqual(MeetingLinks.detect(url: nil, location: "Zoom: https://zoom.us/j/1", notes: "https://teams.live.com/meet/1")?.provider, .zoom)
        XCTAssertEqual(MeetingLinks.detect(url: nil, location: "Sala 3", notes: "link https://teams.live.com/meet/1")?.provider, .teams)
        XCTAssertNil(MeetingLinks.detect(url: URL(string: "https://example.com"), location: nil, notes: nil))
    }

    func testDetectFindsMeetingBehindAWrapperUrl() {
        let wrapped = URL(string: "https://www.google.com/url?q=https://meet.google.com/aaa-bbbb-ccc&sa=D")
        XCTAssertEqual(MeetingLinks.detect(url: wrapped, location: nil, notes: nil)?.provider, .meet)
    }

    func testNextMeetingSkipsPastDeclinedAllDayAndLinkless() {
        let now = stamp(2026, 11, 23, 10)
        func ev(_ id: String, _ h: Int, link: String?, allDay: Bool = false, declined: Bool = false) -> CalEvent {
            var e = makeEvent(id, stamp(2026, 11, 23, h), stamp(2026, 11, 23, h + 1), allDay: allDay)
            e.location = link
            e.declined = declined
            return e
        }
        let events = [ev("past", 8, link: "https://zoom.us/j/1"), ev("declined", 11, link: "https://zoom.us/j/2", declined: true),
                      ev("none", 11, link: nil), ev("allday", 11, link: "https://zoom.us/j/3", allDay: true),
                      ev("later", 15, link: "https://zoom.us/j/5"), ev("soon", 12, link: "https://meet.google.com/aaa-bbbb-ccc")]
        XCTAssertEqual(MeetingLinks.next(in: events, now: now)?.event.id, "soon")
    }

    func testOngoingMeetingCountsAsNext() {
        var e = makeEvent("now", stamp(2026, 11, 23, 9, 30), stamp(2026, 11, 23, 10, 30))
        e.location = "https://zoom.us/j/1"
        XCTAssertEqual(MeetingLinks.next(in: [e], now: stamp(2026, 11, 23, 10))?.event.id, "now")
        XCTAssertNil(MeetingLinks.next(in: [e], now: stamp(2026, 11, 23, 10, 31)))
    }

    func testCountdownText() {
        let start = stamp(2026, 11, 23, 10), end = stamp(2026, 11, 23, 11)
        XCTAssertEqual(MeetingLinks.countdown(to: start, end: end, now: stamp(2026, 11, 23, 9, 56)), "em 4 min")
        XCTAssertEqual(MeetingLinks.countdown(to: start, end: end, now: start.addingTimeInterval(-30)), "em 30 s")
        XCTAssertEqual(MeetingLinks.countdown(to: start, end: end, now: stamp(2026, 11, 23, 8, 55)), "em 1 h 5 min")
        XCTAssertEqual(MeetingLinks.countdown(to: start, end: end, now: stamp(2026, 11, 23, 8)), "em 2 h")
        XCTAssertEqual(MeetingLinks.countdown(to: start, end: end, now: stamp(2026, 11, 21, 10)), "em 2 d")
        XCTAssertEqual(MeetingLinks.countdown(to: start, end: end, now: stamp(2026, 11, 23, 10, 20)), "agora")
        XCTAssertEqual(MeetingLinks.countdown(to: start, end: end, now: stamp(2026, 11, 23, 11)), "terminou")
    }

    func testMenuBarTitleIsClipped() {
        let start = stamp(2026, 11, 23, 10)
        let text = MeetingLinks.menuBarTitle(title: "Reunião de planejamento trimestral", start: start, end: start.addingTimeInterval(3_600),
                                             now: start.addingTimeInterval(-300))
        XCTAssertEqual(text, "Reunião de planejamen… · em 5 min")
        XCTAssertEqual(MeetingLinks.menuBarTitle(title: "Daily", start: start, end: start.addingTimeInterval(60), now: start.addingTimeInterval(-60)), "Daily · em 1 min")
    }

    func testAlertsFireOneMinuteBeforeByDefaultAndOnlyForLinkedFutureEvents() {
        let now = stamp(2026, 11, 23, 9)
        var linked = makeEvent("a", stamp(2026, 11, 23, 10), stamp(2026, 11, 23, 11), title: "Daily")
        linked.url = URL(string: "https://meet.google.com/aaa-bbbb-ccc")
        let plain = makeEvent("b", stamp(2026, 11, 23, 12), stamp(2026, 11, 23, 13))
        var past = makeEvent("c", stamp(2026, 11, 23, 8), stamp(2026, 11, 23, 8, 30))
        past.url = linked.url
        var far = makeEvent("d", stamp(2026, 11, 30, 10), stamp(2026, 11, 30, 11))
        far.url = linked.url
        let alerts = MeetingLinks.alerts(for: [linked, plain, past, far], now: now, leadMinutes: 1)
        XCTAssertEqual(alerts.map(\.key), ["a"])
        XCTAssertEqual(alerts[0].fireDate, stamp(2026, 11, 23, 9, 59))
        XCTAssertEqual(MeetingLinks.alerts(for: [linked], now: now, leadMinutes: 10)[0].fireDate, stamp(2026, 11, 23, 9, 50))
    }

    func testAlertInsideTheLeadWindowStillFiresRightAway() {
        var e = makeEvent("a", stamp(2026, 11, 23, 10), stamp(2026, 11, 23, 11))
        e.url = URL(string: "https://zoom.us/j/1")
        let now = stamp(2026, 11, 23, 9, 59).addingTimeInterval(30)
        let alerts = MeetingLinks.alerts(for: [e], now: now, leadMinutes: 5)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts[0].fireDate, now.addingTimeInterval(1))
    }
}
