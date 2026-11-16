import XCTest
@testable import WispCore

final class TimerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-timers-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testRunningCountsDownFromTheEndDate() {
        let timer = CountdownTimer(duration: 300, startedAt: t0)
        XCTAssertTrue(timer.isRunning)
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(60)), 240)
        XCTAssertEqual(timer.fractionLeft(at: t0.addingTimeInterval(75)), 0.75)
        XCTAssertFalse(timer.isFinished(at: t0.addingTimeInterval(299)))
        XCTAssertTrue(timer.isFinished(at: t0.addingTimeInterval(300)))
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(400)), 0)
    }

    func testPauseFreezesAndResumeShiftsTheEnd() {
        var timer = CountdownTimer(duration: 300, startedAt: t0)
        timer.pause(at: t0.addingTimeInterval(100))
        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(1_000)), 200)
        XCTAssertFalse(timer.isFinished(at: t0.addingTimeInterval(10_000)))
        timer.resume(at: t0.addingTimeInterval(1_000))
        XCTAssertEqual(timer.endDate, t0.addingTimeInterval(1_200))
        XCTAssertEqual(timer.remaining(at: t0.addingTimeInterval(1_100)), 100)
    }

    func testPopFinishedRemovesOnlyEndedRunningTimers() {
        var list = TimerList()
        let short = list.start(duration: 60, at: t0)
        let long = list.start(duration: 600, at: t0)
        let paused = list.start(duration: 30, at: t0)
        list.pause(paused.id, at: t0.addingTimeInterval(10))
        XCTAssertEqual(list.soonest?.id, short.id)
        XCTAssertEqual(list.nextEnd, t0.addingTimeInterval(60))

        let finished = list.popFinished(at: t0.addingTimeInterval(120))
        XCTAssertEqual(finished.map(\.id), [short.id])
        XCTAssertEqual(list.timers.map(\.id), [long.id, paused.id])
        XCTAssertEqual(list.soonest?.id, long.id)

        list.cancel(long.id)
        XCTAssertNil(list.soonest)
        XCTAssertNil(list.nextEnd)
    }

    func testLabelsAndAnnouncement() {
        let whole = CountdownTimer(duration: 25 * 60, startedAt: t0)
        let odd = CountdownTimer(duration: 90, startedAt: t0)
        XCTAssertEqual(whole.label, "Timer 25 min")
        XCTAssertEqual(odd.label, "Timer 1:30")
        XCTAssertNil(TimerList.announcement(for: []))
        XCTAssertEqual(TimerList.announcement(for: [whole]), "Timer 25 min acabou")
        XCTAssertEqual(TimerList.announcement(for: [whole, odd]), "2 timers acabaram")
    }

    func testClockFormat() {
        XCTAssertEqual(TimerFormat.clock(0), "0:00")
        XCTAssertEqual(TimerFormat.clock(0.2), "0:01")
        XCTAssertEqual(TimerFormat.clock(245), "4:05")
        XCTAssertEqual(TimerFormat.clock(1500), "25:00")
        XCTAssertEqual(TimerFormat.clock(3723), "1:02:03")
    }

    func testParseCustomDuration() {
        XCTAssertEqual(TimerFormat.parse("25"), 1500)
        XCTAssertEqual(TimerFormat.parse(" 1:30 "), 90)
        XCTAssertEqual(TimerFormat.parse("0:45"), 45)
        XCTAssertEqual(TimerFormat.parse("99:59"), 5999)
        for bad in ["", "0", "0:00", "1:60", "1:5:0", "abc", "1:", ":30", "100", "-5", "1.5", "١٢"] {
            XCTAssertNil(TimerFormat.parse(bad), bad)
        }
    }

    func testStoreSurvivesReloadWithEndDates() throws {
        var list = TimerList()
        let running = list.start(duration: 1500, at: t0)
        let paused = list.start(duration: 60, at: t0)
        list.pause(paused.id, at: t0.addingTimeInterval(20))
        try TimerStore(directory: dir).save(list)

        let reloaded = TimerStore(directory: dir).load()
        XCTAssertEqual(reloaded, list)
        XCTAssertEqual(reloaded.timers.first { $0.id == running.id }?.endDate, t0.addingTimeInterval(1500))
        XCTAssertEqual(reloaded.timers.first { $0.id == paused.id }?.remaining(at: .distantFuture), 40)
    }

    func testCorruptFileIsMovedAsideAndListStartsEmpty() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("timers.json"))
        let store = TimerStore(directory: dir)
        XCTAssertEqual(store.load(), TimerList())
        XCTAssertNotNil(store.lastRecoveryNote)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("timers.json.bad").path))
    }
}
