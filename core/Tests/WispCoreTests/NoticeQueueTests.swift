import XCTest
@testable import WispCore

final class NoticeQueueTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let all = NoticeSettings()
    private let thread = 42
    private let conversation = UUID()

    private func notice(_ target: NoticeTarget, kind: NoticeKind = .reply, preview: String = "oi", at offset: TimeInterval = 0) -> Notice {
        Notice(kind: kind, title: "t", preview: preview, time: t0.addingTimeInterval(offset), target: target)
    }

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: Offer

    func testFirstNoticeShowsAndExpiresAfterSixSeconds() {
        var queue = NoticeQueue()
        XCTAssertEqual(queue.offer(notice(.topic(thread)), settings: all, visible: [], now: t0), .shown)
        XCTAssertEqual(queue.deadline, at(NoticeQueue.showFor))
        XCTAssertFalse(queue.expire(now: at(5.9)))
        XCTAssertNotNil(queue.current)
        XCTAssertTrue(queue.expire(now: at(6)))
        XCTAssertNil(queue.current)
        XCTAssertNil(queue.deadline)
    }

    func testLaterNoticesQueueInArrivalOrderAndShowOneAfterAnother() {
        var queue = NoticeQueue()
        queue.offer(notice(.topic(1)), settings: all, visible: [], now: t0)
        XCTAssertEqual(queue.offer(notice(.topic(2)), settings: all, visible: [], now: at(1)), .queued)
        XCTAssertEqual(queue.offer(notice(.reminders, kind: .reminder), settings: all, visible: [], now: at(2)), .queued)
        XCTAssertEqual(queue.badge, 2)
        queue.expire(now: at(6))
        XCTAssertEqual(queue.current?.target, .topic(2))
        XCTAssertEqual(queue.deadline, at(12))
        XCTAssertEqual(queue.badge, 1)
        queue.dismiss(now: at(7))
        XCTAssertEqual(queue.current?.target, .reminders)
        XCTAssertEqual(queue.deadline, at(13))
        XCTAssertEqual(queue.badge, 0)
    }

    func testSameSourceUpdatesInPlaceInsteadOfStacking() {
        var queue = NoticeQueue()
        queue.offer(notice(.topic(1), preview: "a"), settings: all, visible: [], now: t0)
        queue.offer(notice(.topic(2), preview: "b"), settings: all, visible: [], now: at(1))
        queue.offer(notice(.topic(3), preview: "c"), settings: all, visible: [], now: at(1))
        XCTAssertEqual(queue.offer(notice(.topic(2), preview: "b2"), settings: all, visible: [], now: at(2)), .updated)
        XCTAssertEqual(queue.pending.map(\.preview), ["b2", "c"])
        XCTAssertEqual(queue.offer(notice(.topic(1), preview: "a2"), settings: all, visible: [], now: at(4)), .updated)
        XCTAssertEqual(queue.current?.preview, "a2")
        XCTAssertEqual(queue.deadline, at(4 + NoticeQueue.showFor), "new content gets the full time again")
    }

    func testReplyAndTopicMessageOfTheSameThreadAreOneSource() {
        let reply = notice(.topic(thread), kind: .reply)
        let topic = notice(.topic(thread), kind: .telegram)
        XCTAssertEqual(reply.sourceId, topic.sourceId)
        XCTAssertNotEqual(notice(.conversation(conversation)).sourceId, reply.sourceId)
    }

    func testQueueKeepsTheNewestWhenFull() {
        var queue = NoticeQueue()
        queue.offer(notice(.topic(0)), settings: all, visible: [], now: t0)
        for index in 1...(NoticeQueue.maxPending + 2) {
            queue.offer(notice(.topic(index)), settings: all, visible: [], now: at(Double(index)))
        }
        XCTAssertEqual(queue.pending.count, NoticeQueue.maxPending)
        XCTAssertEqual(queue.pending.map(\.target), (3...(NoticeQueue.maxPending + 2)).map { NoticeTarget.topic($0) })
    }

    // MARK: Suppression

    func testSuppressedWhenTheSourceIsAlreadyOnScreen() {
        var queue = NoticeQueue()
        let visible: Set<NoticeTarget> = [.conversation(conversation), .topic(thread)]
        XCTAssertEqual(queue.offer(notice(.topic(thread)), settings: all, visible: visible, now: t0), .suppressed)
        XCTAssertEqual(queue.offer(notice(.conversation(conversation), kind: .reply), settings: all, visible: visible, now: t0), .suppressed)
        XCTAssertNil(queue.current)
        XCTAssertEqual(queue.offer(notice(.topic(7)), settings: all, visible: visible, now: t0), .shown)
    }

    func testSuppressedByKindSwitchAndDoNotDisturb() {
        var settings = NoticeSettings()
        settings[.telegram] = false
        var queue = NoticeQueue()
        XCTAssertEqual(queue.offer(notice(.topic(1), kind: .telegram), settings: settings, visible: [], now: t0), .suppressed)
        XCTAssertEqual(queue.offer(notice(.topic(1), kind: .reply), settings: settings, visible: [], now: t0), .shown)
        settings.doNotDisturb = true
        for kind in NoticeKind.allCases {
            XCTAssertFalse(settings.allows(kind))
            XCTAssertEqual(queue.offer(notice(.reminders, kind: kind), settings: settings, visible: [], now: t0), .suppressed)
        }
    }

    func testPruneDropsWhatIsNowOnScreenOrSwitchedOff() {
        var queue = NoticeQueue()
        queue.offer(notice(.topic(1)), settings: all, visible: [], now: t0)
        queue.offer(notice(.reminders, kind: .reminder), settings: all, visible: [], now: at(1))
        queue.offer(notice(.topic(2)), settings: all, visible: [], now: at(1))
        queue.prune(settings: all, visible: [.topic(1)], now: at(2))
        XCTAssertEqual(queue.current?.target, .reminders)
        XCTAssertEqual(queue.deadline, at(2 + NoticeQueue.showFor))
        var quiet = NoticeSettings()
        quiet.doNotDisturb = true
        queue.prune(settings: quiet, visible: [], now: at(3))
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.pending.isEmpty)
    }

    // MARK: Hover

    func testHoverPausesAndLeavingResumesWithTheRestOrAFloor() {
        var queue = NoticeQueue()
        queue.offer(notice(.topic(1)), settings: all, visible: [], now: t0)
        queue.hover(true, now: at(2))
        XCTAssertNil(queue.deadline)
        XCTAssertFalse(queue.expire(now: at(60)))
        XCTAssertNotNil(queue.current)
        queue.hover(false, now: at(60))
        XCTAssertEqual(queue.deadline, at(64), "4 s were left when the pointer arrived")

        queue.hover(true, now: at(63.5))
        queue.hover(false, now: at(70))
        XCTAssertEqual(queue.deadline, at(70 + NoticeQueue.afterHover), "never less than the floor after a hover")
    }

    func testRepeatedHoverReportsDoNotEatTheTime() {
        var queue = NoticeQueue()
        queue.offer(notice(.topic(1)), settings: all, visible: [], now: t0)
        queue.hover(false, now: at(3))
        queue.hover(false, now: at(4))
        XCTAssertEqual(queue.deadline, at(NoticeQueue.showFor))
        queue.hover(true, now: at(5))
        queue.hover(true, now: at(5.5))
        queue.hover(false, now: at(9))
        XCTAssertEqual(queue.deadline, at(9 + NoticeQueue.afterHover))
    }

    func testNextNoticeStaysPausedWhileThePointerIsStillOnTheCard() {
        var queue = NoticeQueue()
        queue.offer(notice(.topic(1)), settings: all, visible: [], now: t0)
        queue.offer(notice(.topic(2)), settings: all, visible: [], now: t0)
        queue.hover(true, now: at(1))
        queue.dismiss(now: at(2))
        XCTAssertEqual(queue.current?.target, .topic(2))
        XCTAssertNil(queue.deadline)
        queue.hover(false, now: at(3))
        XCTAssertEqual(queue.deadline, at(3 + NoticeQueue.showFor))
    }

    func testDismissWhileHoveredLeavesNoStalePause() {
        var queue = NoticeQueue()
        queue.offer(notice(.topic(1)), settings: all, visible: [], now: t0)
        queue.hover(true, now: at(1))
        queue.dismiss(now: at(2))
        XCTAssertNil(queue.current)
        XCTAssertFalse(queue.hovering, "an empty queue has nothing under the pointer")
        queue.offer(notice(.topic(2)), settings: all, visible: [], now: at(30))
        XCTAssertEqual(queue.deadline, at(30 + NoticeQueue.showFor))
        XCTAssertTrue(queue.expire(now: at(36)), "the next card folds on its own")
    }

    func testHoverWithNoCardIsIgnored() {
        var queue = NoticeQueue()
        queue.hover(true, now: t0)
        XCTAssertFalse(queue.hovering)
        queue.offer(notice(.topic(1)), settings: all, visible: [], now: at(1))
        XCTAssertEqual(queue.deadline, at(1 + NoticeQueue.showFor))
    }

    // MARK: Baselines

    func testAlertsBaselineIsForgottenWhileSwitchedOffSoReEnablingIsSilent() {
        let a = urgent("A")
        let b = urgent("B")
        let c = urgent("C")
        let d = urgent("D")
        var quiet = NoticeSettings()
        quiet.doNotDisturb = true
        var seen = NoticeBaselines()
        XCTAssertEqual(seen.alertsRead([a], settings: all), [])
        XCTAssertEqual(seen.alertsRead([a, b], settings: all), [b])
        seen.settingsChanged(quiet)
        XCTAssertNil(seen.alerts, "no read may happen while quiet; the old baseline must not survive")
        XCTAssertEqual(seen.alertsRead([a, b, c], settings: quiet), [])
        XCTAssertNil(seen.alerts)
        XCTAssertEqual(seen.alertsRead([a, b, c], settings: all), [], "first read after quiet is a new baseline")
        XCTAssertEqual(seen.alertsRead([a, b, c, d], settings: all), [d])
        var noReminders = NoticeSettings()
        noReminders[.reminder] = false
        seen.settingsChanged(noReminders)
        XCTAssertNil(seen.alerts)
    }

    func testTopicsBaselineFollowsTheTelegramAndReplySwitches() {
        let geral = TelegramTopic(thread: 1, name: "Geral", sessionId: "s1", cwd: "~", turns: 1)
        var moved = geral
        moved.turns = 2
        var seen = NoticeBaselines()
        XCTAssertEqual(seen.topicsRead([geral], following: nil, wispThreads: [], settings: all), [])
        var replyOnly = NoticeSettings()
        replyOnly[.telegram] = false
        seen.settingsChanged(replyOnly)
        XCTAssertNotNil(seen.topics, "replies still come through topics")
        var neither = replyOnly
        neither[.reply] = false
        seen.settingsChanged(neither)
        XCTAssertNil(seen.topics)
        XCTAssertEqual(seen.topicsRead([moved], following: nil, wispThreads: [], settings: neither), [])
        XCTAssertEqual(seen.topicsRead([moved], following: nil, wispThreads: [], settings: all), [])
        moved.turns = 3
        XCTAssertEqual(seen.topicsRead([moved], following: nil, wispThreads: [], settings: all), [moved])
    }

    func testTakeReturnsTheCardAndMovesOn() {
        var queue = NoticeQueue()
        queue.offer(notice(.topic(1)), settings: all, visible: [], now: t0)
        queue.offer(notice(.reminders, kind: .reminder), settings: all, visible: [], now: t0)
        XCTAssertEqual(queue.take(now: at(1))?.target, .topic(1))
        XCTAssertEqual(queue.current?.target, .reminders)
        XCTAssertEqual(queue.take(now: at(2))?.target, .reminders)
        XCTAssertNil(queue.take(now: at(3)))
    }

    // MARK: Sources

    private func urgent(_ name: String) -> TaskItem {
        TaskList.parse("- **[Ana] X — \(name)**. #urgente <!-- alerta:\(name) -->").first!.items[0]
    }

    func testOnlyAlertsThatAppearAfterTheFirstReadAreNews() {
        let a = urgent("A")
        let b = urgent("B")
        XCTAssertEqual(Notices.newAlerts(old: nil, new: [a]), [])
        XCTAssertEqual(Notices.newAlerts(old: [a], new: [b, a]), [b])
        XCTAssertEqual(Notices.newAlerts(old: [a, b], new: [a]), [])
        XCTAssertEqual(Notices.newAlerts(old: [a], new: [urgent("A")]), [], "same raw line is the same alert")
    }

    func testTopicNewsSkipsTheFollowedTopicAndTopicsWispCreated() {
        let geral = TelegramTopic(thread: 1, name: "Geral", sessionId: "s1", cwd: "~", turns: 3)
        let work = TelegramTopic(thread: 2, name: "Work", sessionId: "s2", cwd: "~", turns: 5)
        var geralMoved = geral
        geralMoved.turns = 4
        var workMoved = work
        workMoved.lastUsed = t0
        let phone = TelegramTopic(thread: 3, name: "Do celular", sessionId: "s3", cwd: "~", turns: 1)
        let mine = TelegramTopic(thread: 4, name: "Do Wisp", sessionId: "s4", cwd: "~", turns: 1)

        XCTAssertEqual(Notices.topicNews(old: nil, new: [geral, work], following: nil, wispThreads: []), [])
        XCTAssertEqual(Notices.topicNews(old: [geral, work], new: [geral, work], following: nil, wispThreads: []), [])
        XCTAssertEqual(
            Notices.topicNews(old: [geral, work], new: [geralMoved, workMoved, phone, mine], following: 2, wispThreads: [4]),
            [geralMoved, phone]
        )
    }

    func testPreviewIsOneTidyLine() {
        XCTAssertEqual(Notices.preview("  oi\n\n  tudo   bem? "), "oi tudo bem?")
        let long = String(repeating: "a", count: Notices.previewLimit + 20)
        let cut = Notices.preview(long)
        XCTAssertEqual(cut.count, Notices.previewLimit)
        XCTAssertTrue(cut.hasSuffix("…"))
    }

    // MARK: Settings

    func testSettingsDefaultAllOnAndDecodeMissingKeys() throws {
        let fresh = NoticeSettings()
        XCTAssertFalse(fresh.doNotDisturb)
        XCTAssertTrue(NoticeKind.allCases.allSatisfy(fresh.allows))
        let partial = try JSONDecoder().decode(NoticeSettings.self, from: Data(#"{"telegram":false}"#.utf8))
        XCTAssertFalse(partial[.telegram])
        XCTAssertTrue(partial[.reply] && partial[.reminder] && partial[.update])
        let saved = try JSONDecoder().decode(WispSettings.self, from: Data(#"{"theme":"lime"}"#.utf8))
        XCTAssertEqual(saved.notices, NoticeSettings())
        var changed = WispSettings.default
        changed.notices.doNotDisturb = true
        let roundTrip = try JSONDecoder().decode(WispSettings.self, from: JSONEncoder().encode(changed))
        XCTAssertTrue(roundTrip.notices.doNotDisturb)
    }

    func testSettingsSavedBeforeUpdateNoticesKeepThemOn() throws {
        let old = try JSONDecoder().decode(NoticeSettings.self, from: Data(
            #"{"reply":true,"telegram":true,"reminder":false,"outbox":true,"doNotDisturb":false}"#.utf8))
        XCTAssertTrue(old.allows(.update))
        XCTAssertFalse(old.allows(.reminder))
    }

    func testUpdateNoticeIsOneCardAndHasItsOwnSwitch() {
        var queue = NoticeQueue()
        let first = Notice(kind: .update, title: "Versão nova do Wisp — 0.2.0", preview: "p", time: t0, target: .update)
        let newer = Notice(kind: .update, title: "Versão nova do Wisp — 0.3.0", preview: "p", time: at(1), target: .update)
        XCTAssertEqual(queue.offer(first, settings: all, visible: [], now: t0), .shown)
        XCTAssertEqual(queue.offer(newer, settings: all, visible: [], now: at(1)), .updated)
        XCTAssertEqual(queue.current?.title, "Versão nova do Wisp — 0.3.0")
        XCTAssertEqual(queue.badge, 0)
        var off = NoticeSettings()
        off.update = false
        var quietQueue = NoticeQueue()
        XCTAssertEqual(quietQueue.offer(first, settings: off, visible: [], now: t0), .suppressed)
        XCTAssertTrue(off.allows(.reply))
    }

    // MARK: Geometry

    func testNoticeFrameDropsFromTheBandOnBothScreens() {
        let macBook = CGRect(x: 0, y: 0, width: 1710, height: 1112)
        let notch = CGRect(x: 751, y: 1074.5, width: 208, height: 37.5)
        let wide = CGRect(x: 0, y: 0, width: 2560, height: 1080)
        for (screen, candidate) in [(macBook, Optional(notch)), (wide, nil)] {
            let band = NotchGeometry.topBand(screen: screen, notch: candidate)
            let card = NotchGeometry.noticeFrame(screen: screen, notch: candidate)
            XCTAssertEqual(card.midX, band.midX)
            XCTAssertEqual(card.maxY, screen.maxY)
            XCTAssertEqual(card.height, band.height + NotchGeometry.noticeSize.height)
            XCTAssertEqual(card.width, NotchGeometry.noticeSize.width)
            XCTAssertTrue(card.contains(band))
        }
    }

    // MARK: Urgent meeting notice

    private func meeting(_ uid: String, tone: Notice.Tone) -> Notice {
        Notice(sourceId: "meeting:\(uid)", kind: .meeting, title: uid, preview: "p", time: t0, target: .event(uid), tone: tone)
    }

    func testNearStartMeetingNoticeJumpsTheQueue() {
        var queue = NoticeQueue()
        queue.offer(notice(.topic(1)), settings: all, visible: [], now: t0)
        queue.offer(notice(.topic(2)), settings: all, visible: [], now: t0)
        XCTAssertEqual(queue.offer(meeting("a", tone: .warning), settings: all, visible: [], now: at(1)), .shown)
        XCTAssertEqual(queue.current?.target, .event("a"))
        XCTAssertEqual(queue.pending.map(\.target), [.topic(1), .topic(2)])
        XCTAssertEqual(queue.deadline, at(1 + NoticeQueue.showFor))
    }

    func testEarlyMeetingNoticeDoesNotJump() {
        var queue = NoticeQueue()
        queue.offer(notice(.topic(1)), settings: all, visible: [], now: t0)
        XCTAssertEqual(queue.offer(meeting("a", tone: .normal), settings: all, visible: [], now: t0), .queued)
        XCTAssertEqual(queue.current?.target, .topic(1))
    }

    func testNearStartMeetingNoticeIsNeverTheOneDropped() {
        var queue = NoticeQueue()
        queue.offer(notice(.topic(0)), settings: all, visible: [], now: t0)
        queue.offer(meeting("a", tone: .warning), settings: all, visible: [], now: t0)
        queue.offer(meeting("b", tone: .warning), settings: all, visible: [], now: t0)
        for thread in 1...(NoticeQueue.maxPending + 2) {
            queue.offer(notice(.topic(thread)), settings: all, visible: [], now: t0)
        }
        let all = [queue.current] + queue.pending.map { Optional($0) }
        XCTAssertTrue(all.contains { $0?.target == .event("a") })
        XCTAssertTrue(all.contains { $0?.target == .event("b") })
        XCTAssertLessThanOrEqual(queue.pending.count, NoticeQueue.maxPending)
    }
}
