import XCTest
@testable import WispCore

final class TimeZoneKitTests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let newYork = TimeZone(identifier: "America/New_York")!
    private let kolkata = TimeZone(identifier: "Asia/Kolkata")!

    func testOffsetLabels() {
        let d = stamp(2026, 11, 23, 12)
        XCTAssertEqual(TimeZoneKit.offsetLabel(saoPaulo, at: d), "GMT-3")
        XCTAssertEqual(TimeZoneKit.offsetLabel(tokyo, at: d), "GMT+9")
        XCTAssertEqual(TimeZoneKit.offsetLabel(kolkata, at: d), "GMT+5:30")
        XCTAssertEqual(TimeZoneKit.offsetLabel(.gmt, at: d), "GMT")
        XCTAssertEqual(TimeZoneKit.offsetLabel(newYork, at: d), "GMT-5")
        XCTAssertEqual(TimeZoneKit.offsetLabel(newYork, at: stamp(2026, 7, 1, 12)), "GMT-4")
    }

    func testCityAndLabel() {
        XCTAssertEqual(TimeZoneKit.city(saoPaulo), "Sao Paulo")
        XCTAssertEqual(TimeZoneKit.city(TimeZone(identifier: "America/Argentina/Buenos_Aires")!), "Buenos Aires")
        XCTAssertEqual(TimeZoneKit.label(tokyo, at: stamp(2026, 11, 23)), "Tokyo (GMT+9)")
    }

    func testClockConversionKeepsTheInstant() {
        let d = stamp(2026, 11, 23, 10)
        XCTAssertEqual(TimeZoneKit.clock(d, in: saoPaulo), "10:00")
        XCTAssertEqual(TimeZoneKit.clock(d, in: tokyo), "22:00")
        XCTAssertEqual(TimeZoneKit.clock(d, in: newYork), "08:00")
        XCTAssertEqual(TimeZoneKit.clock(d, in: kolkata), "18:30")
    }

    func testDayShiftAcrossMidnight() {
        let d = stamp(2026, 11, 23, 15)
        XCTAssertEqual(TimeZoneKit.dayShift(of: d, from: saoPaulo, to: tokyo), 1)
        XCTAssertEqual(TimeZoneKit.dayShift(of: d, from: saoPaulo, to: newYork), 0)
        XCTAssertEqual(TimeZoneKit.dayShift(of: stamp(2026, 11, 23, 1), from: saoPaulo, to: newYork), -1)
        XCTAssertEqual(TimeZoneKit.columnLabel(d, primary: saoPaulo, secondary: tokyo), "03:00 +1")
        XCTAssertEqual(TimeZoneKit.columnLabel(stamp(2026, 11, 23, 1), primary: saoPaulo, secondary: newYork), "23:00 -1")
        XCTAssertEqual(TimeZoneKit.columnLabel(d, primary: saoPaulo, secondary: newYork), "13:00")
    }

    func testReinterpretKeepsWallClockAndMovesTheInstant() {
        let d = stamp(2026, 11, 23, 10)
        let moved = TimeZoneKit.reinterpret(d, from: saoPaulo, to: tokyo)
        XCTAssertEqual(moved, stamp(2026, 11, 23, 10, zone: tokyo))
        XCTAssertEqual(TimeZoneKit.reinterpret(moved, from: tokyo, to: saoPaulo), d)
    }

    func testWallClockAroundDaylightSaving() {
        let before = stamp(2026, 3, 7, 12, zone: newYork), after = stamp(2026, 3, 9, 12, zone: newYork)
        XCTAssertEqual(TimeZoneKit.clock(before, in: saoPaulo), "14:00")
        XCTAssertEqual(TimeZoneKit.clock(after, in: saoPaulo), "13:00")
    }

    func testSearch() {
        XCTAssertTrue(TimeZoneKit.search("tokyo").contains("Asia/Tokyo"))
        XCTAssertTrue(TimeZoneKit.search("sao paulo").contains("America/Sao_Paulo"))
        XCTAssertEqual(TimeZoneKit.search("").first, "America/Sao_Paulo")
        XCTAssertTrue(TimeZoneKit.search("zzzz-nada").isEmpty)
        XCTAssertLessThanOrEqual(TimeZoneKit.search("a", limit: 5).count, 5)
        for id in TimeZoneKit.common { XCTAssertNotNil(TimeZone(identifier: id), id) }
    }

    func testEventTimeZoneAccessor() {
        var e = makeEvent("a", stamp(2026, 11, 23, 10), stamp(2026, 11, 23, 11))
        XCTAssertNil(e.timeZone)
        e.timeZoneID = "Asia/Tokyo"
        XCTAssertEqual(e.timeZone, tokyo)
    }
}
