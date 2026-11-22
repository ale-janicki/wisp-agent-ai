import XCTest
@testable import WispCore

final class AvailabilityTests: XCTestCase {
    private let calendar = makeCalendar()
    private let early = stamp(2026, 11, 22, 0)

    private func iv(_ d: Int, _ h1: Int, _ m1: Int, _ h2: Int, _ m2: Int) -> DateInterval {
        DateInterval(start: stamp(2026, 11, d, h1, m1), end: stamp(2026, 11, d, h2, m2))
    }

    func testMergeOverlappingAndAdjacent() {
        let merged = Availability.merged([iv(23, 10, 0, 11, 0), iv(23, 9, 0, 10, 0), iv(23, 10, 30, 12, 0), iv(23, 14, 0, 15, 0)])
        XCTAssertEqual(merged, [iv(23, 9, 0, 12, 0), iv(23, 14, 0, 15, 0)])
    }

    func testFreeSlotsAroundBusyBlocksInWorkingHours() {
        let busy = [iv(23, 10, 0, 11, 0), iv(23, 14, 0, 15, 30)]
        let slots = Availability.freeSlots(from: stamp(2026, 11, 23), days: 1, busy: busy, hours: .standard, calendar: calendar, now: early)
        XCTAssertEqual(slots, [iv(23, 9, 0, 10, 0), iv(23, 11, 0, 14, 0), iv(23, 15, 30, 18, 0)])
    }

    func testWeekendsAreSkippedByDefault() {
        let slots = Availability.freeSlots(from: stamp(2026, 11, 21), days: 3, busy: [], hours: .standard, calendar: calendar, now: early)
        XCTAssertEqual(slots, [iv(23, 9, 0, 18, 0)])
    }

    func testPastIsNeverOffered() {
        let slots = Availability.freeSlots(from: stamp(2026, 11, 23), days: 1, busy: [], hours: .standard, calendar: calendar, now: stamp(2026, 11, 23, 13, 20))
        XCTAssertEqual(slots, [iv(23, 13, 20, 18, 0)])
        XCTAssertTrue(Availability.freeSlots(from: stamp(2026, 11, 23), days: 1, busy: [], hours: .standard, calendar: calendar, now: stamp(2026, 11, 23, 19)).isEmpty)
    }

    func testMinimumLengthDropsShortGaps() {
        let busy = [iv(23, 9, 0, 9, 45), iv(23, 10, 0, 18, 0)]
        let slots = Availability.freeSlots(from: stamp(2026, 11, 23), days: 1, busy: busy, hours: .standard, calendar: calendar, now: early)
        XCTAssertTrue(slots.isEmpty)
        let loose = Availability.freeSlots(from: stamp(2026, 11, 23), days: 1, busy: busy, hours: .standard, calendar: calendar, now: early, minimumMinutes: 15)
        XCTAssertEqual(loose, [iv(23, 9, 45, 10, 0)])
    }

    func testBufferGrowsBusyBlocks() {
        let slots = Availability.freeSlots(from: stamp(2026, 11, 23), days: 1, busy: [iv(23, 12, 0, 13, 0)], hours: .standard, calendar: calendar,
                                           now: early, bufferMinutes: 15)
        XCTAssertEqual(slots, [iv(23, 9, 0, 11, 45), iv(23, 13, 15, 18, 0)])
    }

    func testBusyThatSpillsOutsideWorkingHours() {
        let busy = [DateInterval(start: stamp(2026, 11, 22, 22), end: stamp(2026, 11, 23, 9, 30)), iv(23, 17, 0, 20, 0)]
        let slots = Availability.freeSlots(from: stamp(2026, 11, 23), days: 1, busy: busy, hours: .standard, calendar: calendar, now: early)
        XCTAssertEqual(slots, [iv(23, 9, 30, 17, 0)])
    }

    func testCustomWorkingDays() {
        let hours = WorkingHours(weekdays: [7], startMinute: 600, endMinute: 720)
        let slots = Availability.freeSlots(from: stamp(2026, 11, 21), days: 2, busy: [], hours: hours, calendar: calendar, now: stamp(2026, 11, 20))
        XCTAssertEqual(slots, [DateInterval(start: stamp(2026, 11, 21, 10), end: stamp(2026, 11, 21, 12))])
    }

    func testWorkingHoursAreSanitised() {
        let hours = WorkingHours(weekdays: [2], startMinute: 2_000, endMinute: 10)
        XCTAssertLessThan(hours.startMinute, hours.endMinute)
        XCTAssertLessThanOrEqual(hours.endMinute, 1_440)
    }

    func testBusyIntervalsIgnoreAllDayDeclinedAndFree() {
        var free = makeEvent("f", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))
        free.busy = false
        var declined = makeEvent("d", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))
        declined.declined = true
        let allDay = makeEvent("a", stamp(2026, 11, 23), stamp(2026, 11, 23, 23, 59), allDay: true)
        let real = makeEvent("r", stamp(2026, 11, 23, 11), stamp(2026, 11, 23, 12))
        XCTAssertEqual(Availability.busyIntervals(from: [free, declined, allDay, real]), [iv(23, 11, 0, 12, 0)])
    }

    func testPortugueseText() {
        let slots = [iv(23, 9, 0, 11, 30), iv(23, 14, 0, 16, 0), iv(24, 10, 0, 12, 0)]
        let text = Availability.text(slots, zone: saoPaulo, language: .pt, at: stamp(2026, 11, 23))
        XCTAssertEqual(text, """
        Tenho estes horários livres (America/Sao_Paulo, GMT-3):
        • seg, 23/11: 09:00–11:30 e 14:00–16:00
        • ter, 24/11: 10:00–12:00
        """)
    }

    func testEnglishTextInAnotherZone() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let text = Availability.text([iv(23, 9, 0, 10, 30), iv(23, 12, 0, 13, 0)], zone: tokyo, language: .en, at: stamp(2026, 11, 23))
        XCTAssertEqual(text, """
        I'm free at these times (Asia/Tokyo, GMT+9):
        • Mon, Nov 23: 9:00 PM–10:30 PM
        • Tue, Nov 24: 12:00 AM–1:00 AM
        """)
    }

    func testTextSplitsSlotsAcrossMidnightAndHandlesEmpty() {
        let slot = DateInterval(start: stamp(2026, 11, 23, 22), end: stamp(2026, 11, 24, 1))
        let text = Availability.text([slot], zone: saoPaulo, language: .pt, at: stamp(2026, 11, 23))
        XCTAssertTrue(text.contains("• seg, 23/11: 22:00–24:00"))
        XCTAssertTrue(text.contains("• ter, 24/11: 00:00–01:00"))
        XCTAssertEqual(Availability.text([], zone: saoPaulo, language: .pt, at: Date()), "Sem horários livres no período.")
        XCTAssertEqual(Availability.text([], zone: saoPaulo, language: .en, at: Date()), "No free times in that period.")
    }

    func testTextMergesTouchingSelectedSlots() {
        let text = Availability.text([iv(23, 9, 0, 10, 0), iv(23, 10, 0, 11, 0)], zone: saoPaulo, language: .en, at: stamp(2026, 11, 23))
        XCTAssertTrue(text.contains("• Mon, Nov 23: 9:00 AM–11:00 AM"))
    }
}
