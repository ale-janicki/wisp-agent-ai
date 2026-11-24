import XCTest
@testable import WispCore

final class InviteNoticesTests: XCTestCase {
    private let now = stamp(2026, 11, 24, 9)

    private func invite(
        _ id: String = "a", start: Date = stamp(2026, 11, 24, 12, 30), end: Date? = nil, status: AttendeeStatus = .pending,
        meIsOrganizer: Bool = false, declined: Bool = false, organizer: String? = "Ana Souza"
    ) -> CalEvent {
        var people = [CalAttendee(name: "Eu", email: "me@example.com", status: status, isOrganizer: meIsOrganizer, isMe: true)]
        if let organizer, !meIsOrganizer {
            people.append(CalAttendee(name: organizer, email: "ana@example.com", status: .accepted, isOrganizer: true))
        }
        var event = makeEvent(id, start, end ?? start.addingTimeInterval(1_800), title: "Catch up diário")
        event.attendees = people
        event.declined = declined
        event.iCalUID = id + "@uid"
        return event
    }

    // MARK: Detection

    func testPendingInviteIsDetected() {
        XCTAssertTrue(Invites.isPending(invite(), now: now))
    }

    func testAnsweredInvitesAreNotPending() {
        for status in [AttendeeStatus.accepted, .tentative, .declined] {
            XCTAssertFalse(Invites.isPending(invite(status: status), now: now), "\(status)")
        }
    }

    func testOrganizerSelfIsNotAnInvite() {
        XCTAssertFalse(Invites.isPending(invite(meIsOrganizer: true), now: now))
    }

    func testDeclinedFlagAndNoAttendeeRowAreNotInvites() {
        XCTAssertFalse(Invites.isPending(invite(declined: true), now: now))
        var other = invite()
        other.attendees = other.attendees.filter { !$0.isMe }
        XCTAssertFalse(Invites.isPending(other, now: now))
        XCTAssertFalse(Invites.isPending(makeEvent("solo", now.addingTimeInterval(3_600), now.addingTimeInterval(7_200)), now: now))
    }

    func testPastOngoingAndHorizon() {
        XCTAssertFalse(Invites.isPending(invite(start: stamp(2026, 11, 24, 7), end: stamp(2026, 11, 24, 8)), now: now))
        XCTAssertTrue(Invites.isPending(invite(start: stamp(2026, 11, 24, 8, 30), end: stamp(2026, 11, 24, 9, 30)), now: now))
        XCTAssertTrue(Invites.isPending(invite(start: stamp(2026, 12, 8, 9)), now: now))
        XCTAssertFalse(Invites.isPending(invite(start: stamp(2026, 12, 8, 9, 1)), now: now))
    }

    func testPendingIsSortedByStart() {
        let later = invite("b", start: stamp(2026, 11, 25, 9))
        let sooner = invite("a")
        XCTAssertEqual(Invites.pending(in: [later, sooner, invite("c", status: .accepted)], now: now).map(\.id), ["a", "b"])
    }

    // MARK: Ledger

    /// A ledger that has settled on `events`: two agreeing reads, 70 s apart.
    private func settled(_ events: [CalEvent]) -> InviteLedger {
        var ledger = InviteLedger()
        _ = ledger.fresh(from: events, now: now)
        _ = ledger.fresh(from: events, now: now.addingTimeInterval(70))
        return ledger
    }

    func testNothingIsAnnouncedWhileLearning() {
        var ledger = InviteLedger()
        XCTAssertTrue(ledger.fresh(from: [invite("a"), invite("b")], now: now).isEmpty)
        XCTAssertFalse(ledger.seeded)
        XCTAssertEqual(ledger.seen.count, 2)
        XCTAssertTrue(ledger.fresh(from: [invite("a"), invite("b")], now: now.addingTimeInterval(70)).isEmpty)
        XCTAssertTrue(ledger.seeded)
    }

    func testReadsCloserThanTheGapDoNotSettle() {
        var ledger = InviteLedger()
        _ = ledger.fresh(from: [invite("a")], now: now)
        _ = ledger.fresh(from: [invite("a")], now: now.addingTimeInterval(10))
        XCTAssertFalse(ledger.seeded)
    }

    func testEmptyFirstReadDoesNotFloodWhenTheStoreCatchesUp() {
        var ledger = InviteLedger()
        XCTAssertTrue(ledger.fresh(from: [], now: now).isEmpty)
        let full = [invite("a"), invite("b"), invite("c")]
        XCTAssertTrue(ledger.fresh(from: full, now: now.addingTimeInterval(70)).isEmpty)
        XCTAssertFalse(ledger.seeded)
        XCTAssertTrue(ledger.fresh(from: full, now: now.addingTimeInterval(140)).isEmpty)
        XCTAssertTrue(ledger.seeded)
        XCTAssertTrue(ledger.fresh(from: full, now: now.addingTimeInterval(210)).isEmpty)
    }

    func testTwoAgreeingEmptyReadsSeedSoTheFirstRealInviteIsAnnounced() {
        var ledger = settled([])
        XCTAssertTrue(ledger.seeded)
        XCTAssertEqual(ledger.fresh(from: [invite("a")], now: now.addingTimeInterval(140)).map(\.id), ["a"])
    }

    func testOnlyNewInvitesAreAnnouncedOnce() {
        var ledger = settled([invite("a")])
        let t = now.addingTimeInterval(200)
        XCTAssertEqual(ledger.fresh(from: [invite("a"), invite("b")], now: t).map(\.id), ["b"])
        XCTAssertTrue(ledger.fresh(from: [invite("a"), invite("b")], now: t.addingTimeInterval(70)).isEmpty)
    }

    func testOneOffEventAtANewTimeIsNew() {
        var ledger = settled([invite("a")])
        XCTAssertEqual(ledger.fresh(from: [invite("a", start: stamp(2026, 11, 25, 12))], now: now.addingTimeInterval(200)).count, 1)
    }

    func testRecurringSeriesIsOneInviteAcrossOccurrences() {
        func occurrence(_ day: Int) -> CalEvent {
            var event = invite("s", start: stamp(2026, 11, day, 10))
            event.isRecurring = true
            return event
        }
        XCTAssertEqual(Invites.key(occurrence(24)), Invites.key(occurrence(25)))
        XCTAssertNotEqual(occurrence(24).uid, occurrence(25).uid)
        var ledger = settled([occurrence(24)])
        let t = now.addingTimeInterval(200)
        XCTAssertTrue(ledger.fresh(from: [occurrence(24), occurrence(25), occurrence(26)], now: t).isEmpty)
        // the first occurrence passes; the next one is the same invite, not a new one
        XCTAssertTrue(ledger.fresh(from: [occurrence(25), occurrence(26)], now: stamp(2026, 11, 24, 11)).isEmpty)
        var fresh = InviteLedger()
        _ = fresh.fresh(from: [], now: now)
        _ = fresh.fresh(from: [], now: now.addingTimeInterval(70))
        XCTAssertEqual(fresh.fresh(from: [occurrence(24), occurrence(25)], now: t).count, 1)
    }

    func testUnchangedRecurringReadLeavesTheLedgerEqualAndRenewsLate() {
        var series = invite("s", start: stamp(2026, 12, 4, 10))
        series.isRecurring = true
        var ledger = settled([series])
        let before = ledger
        _ = ledger.fresh(from: [series], now: now.addingTimeInterval(130))
        XCTAssertEqual(ledger, before)
        let key = Invites.key(series)
        let expiry = ledger.seen[key]!
        // 8 days on, less than 7 days of the 14 are left: the entry is extended
        let later = now.addingTimeInterval(8 * 86_400)
        _ = ledger.fresh(from: [series], now: later)
        XCTAssertGreaterThan(ledger.seen[key]!, expiry)
        XCTAssertEqual(ledger.seen[key]!, later.addingTimeInterval(Invites.horizon))
    }

    func testAnsweredInvitesAreNeverAnnounced() {
        var ledger = settled([])
        XCTAssertTrue(ledger.fresh(from: [invite("a", status: .accepted)], now: now.addingTimeInterval(200)).isEmpty)
        XCTAssertTrue(ledger.seen.isEmpty)
    }

    func testPruneDropsEntriesOfEventsThatPassed() {
        let b = invite("b", start: stamp(2026, 11, 26, 9))
        var ledger = settled([invite("a"), b])
        XCTAssertEqual(ledger.seen.count, 2)
        _ = ledger.fresh(from: [], now: stamp(2026, 11, 24, 13))
        XCTAssertEqual(ledger.seen.keys.sorted(), [Invites.key(b)])
    }

    func testLedgerSurvivesARelaunch() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("invites-\(UUID().uuidString)/seen.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var ledger = InviteLedger.load(from: url)
        XCTAssertFalse(ledger.seeded)
        _ = ledger.fresh(from: [invite("a")], now: now)
        XCTAssertTrue(ledger.save(to: url))
        var again = InviteLedger.load(from: url)
        XCTAssertEqual(again, ledger)
        XCTAssertTrue(again.fresh(from: [invite("a")], now: now.addingTimeInterval(70)).isEmpty)
        XCTAssertTrue(again.seeded)
        try Data("not json".utf8).write(to: url)
        XCTAssertFalse(InviteLedger.load(from: url).seeded)
    }

    func testSaveReportsFailure() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("invites-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(InviteLedger().save(to: dir))
    }

    // MARK: Cap

    func testAtMostThreeNoticesThenOneFold() {
        let events = (1...5).map { invite("e\($0)", start: stamp(2026, 11, 24, 12 + $0)) }
        let cards = Invites.notices(for: events, now: now, timeZone: saoPaulo)
        XCTAssertEqual(cards.count, 4)
        XCTAssertEqual(cards.prefix(3).map(\.kind), [.invite, .invite, .invite])
        XCTAssertEqual(cards[3].title, "Mais 2 convites")
        XCTAssertEqual(cards[3].sourceId, Invites.moreSourceId)
        XCTAssertEqual(cards[3].target, .event(events[3].uid))
        XCTAssertEqual(Invites.notices(for: Array(events.prefix(4)), now: now, timeZone: saoPaulo).last?.title, "Mais 1 convite")
        XCTAssertEqual(Invites.notices(for: Array(events.prefix(3)), now: now, timeZone: saoPaulo).count, 3)
        XCTAssertTrue(Invites.notices(for: [], now: now).isEmpty)
    }

    func testQueueRemovesAnInviteWhereverItIs() {
        let settings = NoticeSettings()
        let cards = Invites.notices(for: (1...2).map { invite("e\($0)", start: stamp(2026, 11, 24, 12 + $0)) }, now: now, timeZone: saoPaulo)
        var queue = NoticeQueue()
        for card in cards { queue.offer(card, settings: settings, visible: [], now: now) }
        queue.remove(sourceId: cards[1].sourceId, now: now)
        XCTAssertEqual(queue.current?.sourceId, cards[0].sourceId)
        XCTAssertTrue(queue.pending.isEmpty)
        queue.remove(sourceId: "invite:ghost", now: now)
        XCTAssertEqual(queue.current?.sourceId, cards[0].sourceId)
        queue.remove(sourceId: cards[0].sourceId, now: now)
        XCTAssertNil(queue.current)
    }

    // MARK: Text

    func testWhenLineRelativeDays() {
        let zone = saoPaulo
        XCTAssertEqual(Invites.whenLine(start: stamp(2026, 11, 24, 12, 30), now: now, timeZone: zone), "hoje às 12:30")
        XCTAssertEqual(Invites.whenLine(start: stamp(2026, 11, 25, 9, 5), now: now, timeZone: zone), "amanhã às 09:05")
        XCTAssertEqual(Invites.whenLine(start: stamp(2026, 11, 30, 14), now: now, timeZone: zone), "segunda, 30/11 às 14:00")
        XCTAssertEqual(Invites.whenLine(start: stamp(2026, 11, 28, 8), now: now, timeZone: zone), "sábado, 28/11 às 08:00")
        XCTAssertEqual(Invites.whenLine(start: stamp(2026, 11, 29, 8), now: now, timeZone: zone), "domingo, 29/11 às 08:00")
    }

    func testWhenLineUsesTheGivenZoneForTheDay() {
        let late = stamp(2026, 11, 24, 23, 30)
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        XCTAssertEqual(Invites.whenLine(start: late, now: now, timeZone: saoPaulo), "hoje às 23:30")
        XCTAssertEqual(Invites.whenLine(start: late, now: now, timeZone: tokyo), "amanhã às 11:30")
    }

    func testWhenLineAllDay() {
        XCTAssertEqual(Invites.whenLine(start: stamp(2026, 11, 25), now: now, timeZone: saoPaulo, allDay: true), "amanhã, dia todo")
    }

    func testPreviewWithProviderLink() {
        var event = invite()
        event.location = "Sala 3"
        event.url = URL(string: "https://teams.microsoft.com/l/meetup-join/abc")
        XCTAssertEqual(Invites.preview(event, now: now, timeZone: saoPaulo), "Convite de Ana Souza\nhoje às 12:30 · Microsoft Teams")
    }

    func testPreviewFallsBackToLocationThenNothing() {
        var event = invite()
        event.location = "Sala 3"
        XCTAssertEqual(Invites.preview(event, now: now, timeZone: saoPaulo), "Convite de Ana Souza\nhoje às 12:30 · Sala 3")
        XCTAssertEqual(Invites.preview(event, now: now, timeZone: saoPaulo, hideDetails: true), "Convite\nhoje às 12:30")
        event.location = nil
        XCTAssertEqual(Invites.preview(event, now: now, timeZone: saoPaulo), "Convite de Ana Souza\nhoje às 12:30")
    }

    func testHiddenTitlesAlsoHideOrganizerProviderAndLocation() {
        var event = invite()
        event.url = URL(string: "https://teams.microsoft.com/l/meetup-join/abc")
        event.location = "Sala 3"
        let notice = Invites.notice(for: event, now: now, timeZone: saoPaulo, hideTitles: true)
        XCTAssertEqual(notice.title, "Reunião")
        XCTAssertEqual(notice.preview, "Convite\nhoje às 12:30")
    }

    func testOrganizerNameFallsBackToEmailThenNothing() {
        var event = invite()
        event.attendees[1] = CalAttendee(name: "", email: "ana@example.com", isOrganizer: true)
        XCTAssertEqual(Invites.organizer(event), "ana@example.com")
        XCTAssertEqual(Invites.preview(event, now: now, timeZone: saoPaulo), "Convite de ana@example.com\nhoje às 12:30")
        event.attendees.remove(at: 1)
        XCTAssertNil(Invites.organizer(event))
        XCTAssertEqual(Invites.preview(event, now: now, timeZone: saoPaulo), "Convite\nhoje às 12:30")
    }

    func testNoticeShape() {
        let event = invite()
        let notice = Invites.notice(for: event, now: now, timeZone: saoPaulo)
        XCTAssertEqual(notice.kind, .invite)
        XCTAssertEqual(notice.target, .event(event.uid))
        XCTAssertEqual(notice.title, "Catch up diário")
        XCTAssertEqual(notice.tone, .normal)
        XCTAssertEqual(notice.sourceId, "invite:" + Invites.key(event))
        XCTAssertEqual(Invites.notice(for: event, now: now, timeZone: saoPaulo, hideTitles: true).title, "Reunião")
    }

    func testRecurringInviteTargetsTheOccurrence() {
        var event = invite()
        event.isRecurring = true
        XCTAssertEqual(Invites.notice(for: event, now: now, timeZone: saoPaulo).target, .event(event.uid))
        XCTAssertTrue(event.uid.contains("@"))
    }

    // MARK: Settings

    func testInviteKindIsOnByDefaultAndFollowsSettings() throws {
        var settings = NoticeSettings()
        XCTAssertTrue(settings.allows(.invite))
        settings.invite = false
        XCTAssertFalse(settings.allows(.invite))
        settings.invite = true
        settings.doNotDisturb = true
        XCTAssertFalse(settings.allows(.invite))
        XCTAssertTrue(try JSONDecoder().decode(NoticeSettings.self, from: Data(#"{"reply":false}"#.utf8)).invite)
        XCTAssertTrue(NoticeKind.allCases.contains(.invite))
    }
}
