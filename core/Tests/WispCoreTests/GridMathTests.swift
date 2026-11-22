import XCTest
@testable import WispCore

final class GridMathTests: XCTestCase {
    private let calendar = makeCalendar()
    private let hour = 48.0

    func testSnapRoundsToQuarterHours() {
        XCTAssertEqual(GridMath.snap(7), 0)
        XCTAssertEqual(GridMath.snap(8), 15)
        XCTAssertEqual(GridMath.snap(52), 45)
        XCTAssertEqual(GridMath.snap(-8), -15)
    }

    func testMinutesFromYAreClamped() {
        XCTAssertEqual(GridMath.minutes(atY: 48, hourHeight: hour), 60)
        XCTAssertEqual(GridMath.minutes(atY: -10, hourHeight: hour), 0)
        XCTAssertEqual(GridMath.minutes(atY: 5_000, hourHeight: hour), 1_440)
        XCTAssertEqual(GridMath.yOffset(forMinutes: 90, hourHeight: hour), 72)
    }

    func testCreateByDragSnapsBothEdges() {
        let r = GridMath.createRange(fromY: 10 * hour + 1, toY: 11.5 * hour - 1, hourHeight: hour)
        XCTAssertEqual(r.start, 600)
        XCTAssertEqual(r.end, 690)
    }

    func testCreateByDragUpwardsIsNormalised() {
        let r = GridMath.createRange(fromY: 12 * hour, toY: 10 * hour, hourHeight: hour)
        XCTAssertEqual([r.start, r.end], [600, 720])
    }

    func testClickWithoutDragCreatesOneHour() {
        let r = GridMath.createRange(fromY: 9 * hour + 3, toY: 9 * hour + 3, hourHeight: hour)
        XCTAssertEqual([r.start, r.end], [540, 600])
    }

    func testTinyDragKeepsMinimumLength() {
        let r = GridMath.createRange(fromY: 9 * hour, toY: 9 * hour + 6, hourHeight: hour)
        XCTAssertEqual(r.end - r.start, 15)
    }

    func testClickNearMidnightStaysInsideTheDay() {
        let r = GridMath.createRange(fromY: 23.9 * hour, toY: 23.9 * hour, hourHeight: hour)
        XCTAssertEqual(r.end, 1_440)
        XCTAssertGreaterThanOrEqual(r.start, 0)
    }

    func testMoveKeepsDurationAndSnapsStart() {
        let span = TimeSpan(start: stamp(2026, 11, 23, 10), end: stamp(2026, 11, 23, 11, 30))
        let moved = GridMath.move(span, deltaMinutes: 38, deltaDays: 0, calendar: calendar)
        XCTAssertEqual(moved.start, stamp(2026, 11, 23, 10, 45))
        XCTAssertEqual(moved.end, stamp(2026, 11, 23, 12, 15))
    }

    func testMoveAcrossDays() {
        let span = TimeSpan(start: stamp(2026, 11, 23, 10), end: stamp(2026, 11, 23, 11))
        let moved = GridMath.move(span, deltaMinutes: 0, deltaDays: 2, calendar: calendar)
        XCTAssertEqual(moved.start, stamp(2026, 11, 25, 10))
        XCTAssertEqual(moved.end, stamp(2026, 11, 25, 11))
        let back = GridMath.move(span, deltaMinutes: 60, deltaDays: -1, calendar: calendar)
        XCTAssertEqual(back.start, stamp(2026, 11, 22, 11))
    }

    func testMoveClampsInsideTheDay() {
        let span = TimeSpan(start: stamp(2026, 11, 23, 22), end: stamp(2026, 11, 23, 23))
        let late = GridMath.move(span, deltaMinutes: 600, deltaDays: 0, calendar: calendar)
        XCTAssertEqual(late.end, stamp(2026, 11, 24, 0))
        let early = GridMath.move(span, deltaMinutes: -3_000, deltaDays: 0, calendar: calendar)
        XCTAssertEqual(early.start, stamp(2026, 11, 23, 0))
    }

    func testMoveSnapsOffGridStartAbsolutely() {
        let span = TimeSpan(start: stamp(2026, 11, 23, 10, 7), end: stamp(2026, 11, 23, 11, 7))
        XCTAssertEqual(GridMath.move(span, deltaMinutes: 0, deltaDays: 0, calendar: calendar).start, stamp(2026, 11, 23, 10))
    }

    func testResizeEndSnapsAndHonoursMinimum() {
        let span = TimeSpan(start: stamp(2026, 11, 23, 10), end: stamp(2026, 11, 23, 11))
        XCTAssertEqual(GridMath.resizeEnd(span, deltaMinutes: 22, calendar: calendar).end, stamp(2026, 11, 23, 11, 15))
        XCTAssertEqual(GridMath.resizeEnd(span, deltaMinutes: -600, calendar: calendar).end, stamp(2026, 11, 23, 10, 15))
        XCTAssertEqual(GridMath.resizeEnd(span, deltaMinutes: 22, calendar: calendar).start, span.start)
    }

    func testResizeStartSnapsAndHonoursMinimum() {
        let span = TimeSpan(start: stamp(2026, 11, 23, 10), end: stamp(2026, 11, 23, 11))
        XCTAssertEqual(GridMath.resizeStart(span, deltaMinutes: -20, calendar: calendar).start, stamp(2026, 11, 23, 9, 45))
        XCTAssertEqual(GridMath.resizeStart(span, deltaMinutes: 600, calendar: calendar).start, stamp(2026, 11, 23, 10, 45))
        XCTAssertEqual(GridMath.resizeStart(span, deltaMinutes: -6_000, calendar: calendar).start, stamp(2026, 11, 23, 0))
    }

    func testDayDeltaFromHorizontalTranslation() {
        XCTAssertEqual(GridMath.dayDelta(forTranslation: 160, columnWidth: 100), 2)
        XCTAssertEqual(GridMath.dayDelta(forTranslation: 40, columnWidth: 100), 0)
        XCTAssertEqual(GridMath.dayDelta(forTranslation: -60, columnWidth: 100), -1)
        XCTAssertEqual(GridMath.dayDelta(forTranslation: 500, columnWidth: 0), 0)
    }

    func testSpanOnDay() {
        let s = GridMath.span(onDay: stamp(2026, 11, 23, 15), startMinute: 600, endMinute: 660, calendar: calendar)!
        XCTAssertEqual(s.start, stamp(2026, 11, 23, 10))
        XCTAssertEqual(s.end, stamp(2026, 11, 23, 11))
    }

    func testAllDayEndIsLastSecondOfTheDay() {
        let end = CalendarDates.allDayEnd(lastDay: stamp(2026, 11, 23, 15), calendar: calendar)
        XCTAssertEqual(end, stamp(2026, 11, 23, 23, 59).addingTimeInterval(59))
        let event = makeEvent("a", stamp(2026, 11, 23), end, allDay: true)
        XCTAssertEqual(CalendarDates.lastDay(of: event, calendar: calendar), stamp(2026, 11, 23))
    }
}
