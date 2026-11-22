import XCTest
@testable import WispCore

final class CalendarPerformanceTests: XCTestCase {
    private let calendar = makeCalendar()

    private func synthetic(count: Int) -> [CalEvent] {
        let origin = stamp(2026, 1, 1)
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { n in
            let day = Int.random(in: 0..<700, using: &generator)
            let minute = Int.random(in: 7 * 4..<19 * 4, using: &generator) * 15
            let start = calendar.date(byAdding: .minute, value: day * 1_440 + minute, to: origin)!
            return makeEvent("e\(n)", start, start.addingTimeInterval(Double(Int.random(in: 1...8, using: &generator)) * 1_800), title: "Evento \(n)")
        }
    }

    private func milliseconds(_ block: () async throws -> Void) async rethrows -> Double {
        let began = DispatchTime.now().uptimeNanoseconds
        try await block()
        return Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
    }

    func testMonthAndWeekPipelineOnTwoThousandEvents() async throws {
        let backend = FakeCalendarBackend()
        backend.events = synthetic(count: 2_000)
        var index = EventIndex(calendar: calendar)
        let monthStart = stamp(2026, 6, 1), monthEnd = stamp(2026, 7, 1)
        let weekStart = stamp(2026, 6, 8), weekEnd = stamp(2026, 6, 15)

        var monthRuns: [Double] = [], weekRuns: [Double] = []
        for _ in 0..<20 {
            monthRuns.append(try await milliseconds {
                let found = try await backend.events(from: monthStart, to: monthEnd)
                index.replace(range: index.dayNumber(monthStart)..<index.dayNumber(monthEnd), with: found)
                for day in index.dayNumber(monthStart)..<index.dayNumber(monthEnd) {
                    _ = EventLayout.layout(index.events(onDay: day), on: index.date(forDayNumber: day), calendar: calendar)
                }
            })
            weekRuns.append(try await milliseconds {
                let found = try await backend.events(from: weekStart, to: weekEnd)
                index.replace(range: index.dayNumber(weekStart)..<index.dayNumber(weekEnd), with: found)
                for day in index.dayNumber(weekStart)..<index.dayNumber(weekEnd) {
                    _ = EventLayout.layout(index.events(onDay: day), on: index.date(forDayNumber: day), calendar: calendar)
                }
            })
        }
        let yearMs = try await milliseconds {
            let found = try await backend.events(from: stamp(2026, 1, 1), to: stamp(2027, 1, 1))
            var year = EventIndex(calendar: calendar)
            year.replace(range: year.dayNumber(stamp(2026, 1, 1))..<year.dayNumber(stamp(2027, 1, 1)), with: found)
            XCTAssertGreaterThan(found.count, 800)
        }
        let month = monthRuns.sorted()[monthRuns.count / 2], week = weekRuns.sorted()[weekRuns.count / 2]
        print("PERF month fetch+index+layout median \(String(format: "%.2f", month)) ms, week \(String(format: "%.2f", week)) ms, full year index \(String(format: "%.2f", yearMs)) ms, events 2000")
        XCTAssertLessThan(month, 100)
        XCTAssertLessThan(week, 50)
        XCTAssertLessThan(yearMs, 500)
    }
}
