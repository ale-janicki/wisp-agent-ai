import XCTest
@testable import WispCore

final class EventLayoutTests: XCTestCase {
    private let calendar = makeCalendar()
    private let day = stamp(2026, 11, 23)

    private func seg(_ id: String, _ s: Int, _ e: Int) -> DaySegment { DaySegment(id: id, startMinute: s, endMinute: e) }

    func testNonOverlappingEventsUseFullWidth() {
        let placed = EventLayout.place([seg("a", 60, 120), seg("b", 120, 180)])
        XCTAssertEqual(placed.map(\.columns), [1, 1])
        XCTAssertEqual(placed.map(\.span), [1, 1])
    }

    func testTwoOverlappingEventsSitSideBySide() {
        let placed = EventLayout.place([seg("a", 60, 120), seg("b", 90, 150)])
        let a = placed.first { $0.id == "a" }!, b = placed.first { $0.id == "b" }!
        XCTAssertEqual([a.column, b.column], [0, 1])
        XCTAssertEqual([a.columns, b.columns], [2, 2])
        XCTAssertEqual(b.leadingFraction, 0.5)
        XCTAssertEqual(b.widthFraction, 0.5)
    }

    func testChainedOverlapReusesAFreedColumn() {
        let placed = EventLayout.place([seg("a", 0, 60), seg("b", 30, 90), seg("c", 60, 120)])
        let c = placed.first { $0.id == "c" }!
        XCTAssertEqual(c.column, 0)
        XCTAssertEqual(placed.map(\.columns), [2, 2, 2])
    }

    func testEventExpandsIntoFreeColumnsToTheRight() {
        let placed = EventLayout.place([seg("long", 0, 240), seg("x", 0, 60), seg("y", 30, 90)])
        let long = placed.first { $0.id == "long" }!
        XCTAssertEqual(long.column, 0)
        XCTAssertEqual(long.columns, 3)
        let x = placed.first { $0.id == "x" }!
        XCTAssertEqual(x.column, 1)
        XCTAssertEqual(x.span, 1)
        let y = placed.first { $0.id == "y" }!
        XCTAssertEqual(y.column, 2)
    }

    func testLastColumnSpansWhenNeighbourIsFreeThere() {
        let placed = EventLayout.place([seg("a", 0, 120), seg("b", 0, 60), seg("c", 60, 120)])
        let c = placed.first { $0.id == "c" }!
        XCTAssertEqual(c.column, 1)
        XCTAssertEqual(placed.first { $0.id == "b" }!.column, 1)
    }

    func testSeparateClustersDoNotShareColumns() {
        let placed = EventLayout.place([seg("a", 0, 60), seg("b", 30, 90), seg("c", 300, 360)])
        XCTAssertEqual(placed.first { $0.id == "c" }!.columns, 1)
        XCTAssertEqual(placed.first { $0.id == "a" }!.columns, 2)
    }

    func testIdenticalTimesGetStableDistinctColumns() {
        let placed = EventLayout.place([seg("b", 60, 120), seg("a", 60, 120), seg("c", 60, 120)])
        XCTAssertEqual(placed.sorted { $0.id < $1.id }.map(\.column), [0, 1, 2])
    }

    func testSegmentClampsMultiDayEventToTheDay() {
        let event = makeEvent("n", stamp(2026, 11, 22, 22), stamp(2026, 11, 23, 2))
        let first = EventLayout.segment(of: event, on: stamp(2026, 11, 22), calendar: calendar)!
        XCTAssertEqual([first.startMinute, first.endMinute], [1_320, 1_440])
        let second = EventLayout.segment(of: event, on: day, calendar: calendar)!
        XCTAssertEqual([second.startMinute, second.endMinute], [0, 120])
        XCTAssertNil(EventLayout.segment(of: event, on: stamp(2026, 11, 24), calendar: calendar))
    }

    func testAllDayAndOutsideEventsHaveNoSegment() {
        XCTAssertNil(EventLayout.segment(of: makeEvent("a", day, day.addingTimeInterval(86_399), allDay: true), on: day, calendar: calendar))
        XCTAssertNil(EventLayout.segment(of: makeEvent("b", stamp(2026, 11, 22, 9), stamp(2026, 11, 22, 10)), on: day, calendar: calendar))
    }

    func testShortEventsGetAMinimumVisibleHeight() {
        let tiny = makeEvent("t", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 9, 5))
        let segment = EventLayout.segment(of: tiny, on: day, calendar: calendar)!
        XCTAssertEqual(segment.endMinute - segment.startMinute, EventLayout.minimumVisibleMinutes)
        let zero = makeEvent("z", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 9))
        XCTAssertNotNil(EventLayout.segment(of: zero, on: day, calendar: calendar))
    }

    func testEventEndingAtMidnightStaysOnItsDay() {
        let late = makeEvent("l", stamp(2026, 11, 23, 23), stamp(2026, 11, 24, 0))
        XCTAssertNotNil(EventLayout.segment(of: late, on: day, calendar: calendar))
        XCTAssertNil(EventLayout.segment(of: late, on: stamp(2026, 11, 24), calendar: calendar))
    }

    func testLayoutOverEvents() {
        let events = [makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10)),
                      makeEvent("b", stamp(2026, 11, 23, 9, 30), stamp(2026, 11, 23, 10, 30)),
                      makeEvent("d", stamp(2026, 11, 23), stamp(2026, 11, 23, 23, 59), allDay: true)]
        XCTAssertEqual(EventLayout.layout(events, on: day, calendar: calendar).count, 2)
    }

    func testIndexPutsMultiDayEventOnEachDayAndSortsAllDayFirst() {
        var index = EventIndex(calendar: calendar)
        let first = index.dayNumber(stamp(2026, 11, 22))
        let events = [makeEvent("n", stamp(2026, 11, 22, 22), stamp(2026, 11, 24, 2)),
                      makeEvent("a", stamp(2026, 11, 23), stamp(2026, 11, 23, 23, 59), allDay: true),
                      makeEvent("m", stamp(2026, 11, 23, 8), stamp(2026, 11, 23, 9))]
        index.replace(range: first..<(first + 5), with: events)
        XCTAssertEqual(index.events(on: stamp(2026, 11, 22)).map(\.id), ["n"])
        XCTAssertEqual(index.events(on: stamp(2026, 11, 23)).map(\.id), ["a", "n", "m"])
        XCTAssertEqual(index.events(on: stamp(2026, 11, 23)).first?.id, "a")
        XCTAssertEqual(index.events(on: stamp(2026, 11, 24)).map(\.id), ["n"])
        XCTAssertEqual(index.events(on: stamp(2026, 11, 25)).map(\.id), [])
    }

    func testIndexReplaceClearsOnlyTheRange() {
        var index = EventIndex(calendar: calendar)
        let d = index.dayNumber(stamp(2026, 11, 23))
        index.replace(range: d..<(d + 2), with: [makeEvent("a", stamp(2026, 11, 23, 9), stamp(2026, 11, 23, 10))])
        index.replace(range: (d + 1)..<(d + 3), with: [makeEvent("b", stamp(2026, 11, 24, 9), stamp(2026, 11, 24, 10))])
        XCTAssertEqual(index.events(onDay: d).map(\.id), ["a"])
        XCTAssertEqual(index.events(onDay: d + 1).map(\.id), ["b"])
    }

    func testIndexIgnoresEventsOutsideTheRange() {
        var index = EventIndex(calendar: calendar)
        let d = index.dayNumber(stamp(2026, 11, 23))
        index.replace(range: d..<(d + 1), with: [makeEvent("far", stamp(2026, 12, 25, 9), stamp(2026, 12, 25, 10))])
        XCTAssertTrue(index.byDay.isEmpty)
    }
}
