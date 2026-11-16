import XCTest
@testable import WispCore

final class AgendaListTests: XCTestCase {
    private let json = #"""
    [{"id":"b","account":"trabalho","title":"Reunião","start":"2026-11-16T15:00:00-03:00","end":"2026-11-16T16:00:00-03:00","allDay":false,"location":"Sala","link":"https://meet.example.com/x","response":"accepted"},
     {"id":"a","account":"pessoal","title":"Café","start":"2026-11-16T09:20:00-03:00","end":"2026-11-16T09:40:00-03:00","allDay":false,"link":null},
     {"id":"d","title":"Feriado","start":"2026-11-16","end":"2026-11-17","allDay":true},
     {"id":"c","title":"Recusado","start":"2026-11-16T10:00:00-03:00","end":"2026-11-16T11:00:00-03:00","allDay":false,"response":"declined","link":"javascript:alert(1)"},
     {"id":"e","title":"Depois","start":"2026-11-16T17:00:00-03:00","end":"2026-11-16T17:30:00-03:00","allDay":false},
     {"title":"sem id"}, {"id":"f","title":"sem hora","allDay":false}]
    """#

    private func at(_ hhmm: String) -> Date {
        AlertList.date("2026-11-16T\(hhmm):00-03:00")!
    }

    func testParsesAllDayFirstThenByStart() throws {
        let events = try AgendaList.parse(Data(json.utf8))
        XCTAssertEqual(events.map(\.id), ["d", "a", "c", "b", "e"])
        XCTAssertTrue(events[0].allDay)
        XCTAssertEqual(events[3].calendar, "trabalho")
        XCTAssertEqual(events[3].link?.absoluteString, "https://meet.example.com/x")
        XCTAssertEqual(events[3].start, at("15:00"))
        XCTAssertTrue(events[2].declined)
        XCTAssertNil(events[2].link, "only http(s) links open")
    }

    func testMarkersNowAndNext() throws {
        let events = try AgendaList.parse(Data(json.utf8))
        XCTAssertEqual(AgendaList.markers(events, now: at("15:30")), ["b": .now, "e": .next])
        XCTAssertEqual(AgendaList.markers(events, now: at("09:50")), ["b": .next], "declined 10:00 is skipped")
        XCTAssertEqual(AgendaList.markers(events, now: at("18:00")), [:])
    }

    func testRemainingCountsTimedNotDeclinedNotEnded() throws {
        let events = try AgendaList.parse(Data(json.utf8))
        XCTAssertEqual(AgendaList.remaining(events, now: at("08:00")), 3)
        XCTAssertEqual(AgendaList.remaining(events, now: at("15:30")), 2)
        XCTAssertEqual(AgendaList.remaining(events, now: at("17:30")), 0)
    }

    func testGarbage() {
        XCTAssertEqual(try AgendaList.parse(Data("[]".utf8)), [])
        XCTAssertThrowsError(try AgendaList.parse(Data("Hoje - pessoal".utf8))) { error in
            XCTAssertEqual(error as? AgendaListError, .notJSON)
        }
    }
}
