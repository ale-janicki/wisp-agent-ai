import XCTest
@testable import WispCore

final class MeetingNoticePlannerTests: XCTestCase {
    private func event() -> CalEvent {
        var e = makeEvent("a", stamp(2026, 11, 23, 10), stamp(2026, 11, 23, 11), title: "Planejamento")
        e.url = URL(string: "https://zoom.us/j/1")
        return e
    }

    private func plan() -> [MeetingLinks.Alert] {
        MeetingLinks.alerts(for: [event()], now: stamp(2026, 11, 23, 9), leadMinutes: 1, earlyMinutes: 10)
    }

    func testNothingIsDueBeforeItsTime() {
        XCTAssertTrue(MeetingNoticePlanner.due(alerts: plan(), posted: [], now: stamp(2026, 11, 23, 9, 49)).isEmpty)
    }

    func testEachAlertIsDueOnceAtItsTime() {
        var posted = Set<String>()
        let early = MeetingNoticePlanner.due(alerts: plan(), posted: posted, now: stamp(2026, 11, 23, 9, 50))
        XCTAssertEqual(early.map(\.id), ["a#early"])
        posted.formUnion(early.map(\.id))
        XCTAssertTrue(MeetingNoticePlanner.due(alerts: plan(), posted: posted, now: stamp(2026, 11, 23, 9, 55)).isEmpty)
        let start = MeetingNoticePlanner.due(alerts: plan(), posted: posted, now: stamp(2026, 11, 23, 9, 59))
        XCTAssertEqual(start.map(\.id), ["a#start"])
        posted.formUnion(start.map(\.id))
        XCTAssertTrue(MeetingNoticePlanner.due(alerts: plan(), posted: posted, now: stamp(2026, 11, 23, 9, 59).addingTimeInterval(50)).isEmpty)
    }

    func testBothDueAtOnceComeInFireOrder() {
        XCTAssertEqual(MeetingNoticePlanner.due(alerts: plan(), posted: [], now: stamp(2026, 11, 23, 9, 59)).map(\.id), ["a#early", "a#start"])
    }

    func testRememberedDropsIdsOutOfThePlan() {
        let kept = MeetingNoticePlanner.remembered(posted: ["a#early", "gone#start"], alerts: plan())
        XCTAssertEqual(kept, ["a#early"])
    }

    func testNoticeForEarlyAndNearStart() {
        let alerts = plan()
        let early = MeetingNoticePlanner.notice(for: alerts[0], now: stamp(2026, 11, 23, 9, 50))
        XCTAssertEqual(early.kind, .meeting)
        XCTAssertEqual(early.target, .event("a"))
        XCTAssertEqual(early.sourceId, "meeting:a#early")
        XCTAssertEqual(early.title, "Planejamento")
        XCTAssertEqual(early.preview, "Começa em 10 min")
        XCTAssertEqual(early.tone, .normal)
        let start = MeetingNoticePlanner.notice(for: alerts[1], now: stamp(2026, 11, 23, 9, 59).addingTimeInterval(40))
        XCTAssertEqual(start.preview, "Começando agora")
        XCTAssertEqual(start.tone, .warning)
        XCTAssertNotEqual(early.sourceId, start.sourceId)
    }

    func testTitleHiddenWhenAskedAndMeetingNoticesFollowSettings() {
        let hidden = MeetingLinks.alerts(for: [event()], now: stamp(2026, 11, 23, 9), leadMinutes: 1, earlyMinutes: 0, hideTitles: true)
        XCTAssertEqual(MeetingNoticePlanner.notice(for: hidden[0], now: stamp(2026, 11, 23, 9, 59)).title, "Reunião")
        var settings = NoticeSettings()
        XCTAssertTrue(settings.allows(.meeting))
        settings.meeting = false
        XCTAssertFalse(settings.allows(.meeting))
        var dnd = NoticeSettings()
        dnd.doNotDisturb = true
        XCTAssertFalse(dnd.allows(.meeting))
        XCTAssertTrue(try JSONDecoder().decode(NoticeSettings.self, from: Data(#"{"reply":false}"#.utf8)).meeting)
    }

    func testSystemNotificationsDefaultOffAndDecodeTolerant() throws {
        XCTAssertFalse(AgendaPreferences().systemMeetingNotifications)
        XCTAssertFalse(try JSONDecoder().decode(AgendaPreferences.self, from: Data("{}".utf8)).systemMeetingNotifications)
        XCTAssertFalse(try JSONDecoder().decode(AgendaPreferences.self, from: Data(#"{"systemMeetingNotifications":"x"}"#.utf8)).systemMeetingNotifications)
        XCTAssertTrue(try JSONDecoder().decode(AgendaPreferences.self, from: Data(#"{"systemMeetingNotifications":true}"#.utf8)).systemMeetingNotifications)
    }

    func testDueAlertMissingFromTheNewPlanIsCarriedOverAndPostedOnce() {
        let old = plan()
        let now = stamp(2026, 11, 23, 9, 55)
        let fresh = MeetingLinks.alerts(for: [event()], now: now, leadMinutes: 1, earlyMinutes: 10)
        XCTAssertEqual(fresh.map(\.id), ["a#start"])
        var posted = Set<String>()
        let merged = MeetingNoticePlanner.carryOver(old: old, new: fresh, posted: posted, now: now)
        let due = MeetingNoticePlanner.due(alerts: merged, posted: posted, now: now)
        XCTAssertEqual(due.map(\.id), ["a#early"])
        posted.formUnion(due.map(\.id))
        let again = MeetingNoticePlanner.carryOver(old: merged, new: fresh, posted: posted, now: now)
        XCTAssertTrue(MeetingNoticePlanner.due(alerts: again, posted: posted, now: now).isEmpty)
        XCTAssertEqual(MeetingNoticePlanner.carryOver(old: old, new: fresh, posted: ["a#early"], now: now).map(\.id), ["a#start"])
        XCTAssertEqual(MeetingNoticePlanner.carryOver(old: old, new: fresh, posted: [], now: stamp(2026, 11, 23, 10, 5)).map(\.id), ["a#start"])
    }
}
