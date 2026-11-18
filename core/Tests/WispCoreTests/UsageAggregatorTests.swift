import XCTest
@testable import WispCore

final class UsageAggregatorTests: XCTestCase {
    private var root: URL!
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    private let now = Date(timeIntervalSince1970: 1_794_841_200)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-usage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("p/sub"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func assistant(id: String, at stamp: String, input: Int, output: Int, cacheCreation: Int = 0, cacheRead: Int = 0, model: String = "claude-x") -> String {
        #"{"type":"assistant","timestamp":"\#(stamp)","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(cacheCreation),"cache_read_input_tokens":\#(cacheRead)}}}"#
    }

    private func write(_ lines: [String], to relative: String, trailingNewline: Bool = true, modified: Date? = nil) throws {
        let url = root.appendingPathComponent(relative)
        try Data((lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    func testAggregatesTodayAndWeek() throws {
        try write([
            assistant(id: "m1", at: "2026-11-16T10:00:00.123Z", input: 10, output: 20, cacheCreation: 30, cacheRead: 40),
            assistant(id: "m1", at: "2026-11-16T10:00:00.456Z", input: 10, output: 20, cacheCreation: 30, cacheRead: 40),
            #"{"type":"user","timestamp":"2026-11-16T10:00:01Z","message":{"content":"oi","usage":{"input_tokens":999}}}"#,
            "not json",
            assistant(id: "m2", at: "2026-11-15T23:59:59Z", input: 1, output: 2),
            assistant(id: "m3", at: "2026-11-09T12:00:00Z", input: 500, output: 500),
            assistant(id: "m4", at: "2026-11-16T11:00:00Z", input: 7, output: 7, model: "<synthetic>"),
        ], to: "p/a.jsonl")
        try write([assistant(id: "m5", at: "2026-11-10T08:00:00Z", input: 3, output: 4)], to: "p/sub/agent.jsonl", trailingNewline: false)
        try write([assistant(id: "m6", at: "2026-11-16T09:00:00Z", input: 1000, output: 1000)], to: "p/old.jsonl", modified: now.addingTimeInterval(-10 * 86_400))
        try write([assistant(id: "m7", at: "2026-11-16T09:00:00Z", input: 1000, output: 1000)], to: "p/notes.txt")

        let summary = UsageAggregator.aggregate(root: root, now: now, calendar: calendar)

        XCTAssertEqual(summary.days.count, 7)
        XCTAssertEqual(summary.days.first?.day, calendar.date(from: DateComponents(year: 2026, month: 11, day: 10)))
        XCTAssertEqual(summary.today.day, calendar.date(from: DateComponents(year: 2026, month: 11, day: 16)))
        XCTAssertEqual(summary.today.messages, 1)
        XCTAssertEqual(summary.today.inputTokens, 10)
        XCTAssertEqual(summary.today.outputTokens, 20)
        XCTAssertEqual(summary.today.cacheCreationTokens, 30)
        XCTAssertEqual(summary.today.cacheReadTokens, 40)
        XCTAssertEqual(summary.today.billableTokens, 60)
        XCTAssertEqual(summary.today.totalTokens, 100)
        XCTAssertEqual(summary.days[5].billableTokens, 3)
        XCTAssertEqual(summary.days[0].billableTokens, 7)
        XCTAssertEqual(summary.days.map(\.messages), [1, 0, 0, 0, 0, 1, 1])
        XCTAssertEqual(summary.billableTokens, 70)
        XCTAssertEqual(summary.cacheReadTokens, 40)
        XCTAssertEqual(summary.totalTokens, 110)
    }

    func testIndexReadsOnlyWhatChanged() throws {
        let url = root.appendingPathComponent("p/a.jsonl")
        try write([assistant(id: "m1", at: "2026-11-16T10:00:00Z", input: 1, output: 1)], to: "p/a.jsonl")
        let index = UsageIndex(root: root)
        XCTAssertEqual(index.summary(now: now, calendar: calendar).today.billableTokens, 2)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((assistant(id: "m2", at: "2026-11-16T11:00:00Z", input: 10, output: 10) + "\n").utf8))
        try handle.write(contentsOf: Data(assistant(id: "m3", at: "2026-11-16T12:00:00Z", input: 100, output: 100).utf8))
        try handle.close()
        XCTAssertEqual(index.summary(now: now, calendar: calendar).today.billableTokens, 222, "appended lines and a tail without newline")
        XCTAssertEqual(index.summary(now: now, calendar: calendar).today.messages, 3, "the tail is not counted twice")

        try write([assistant(id: "m9", at: "2026-11-16T09:00:00Z", input: 5, output: 0)], to: "p/a.jsonl")
        XCTAssertEqual(index.summary(now: now, calendar: calendar).today.billableTokens, 5, "a rewritten, shorter file is read again")

        try write([assistant(id: "m8", at: "2026-11-16T09:00:00Z", input: 7, output: 0)], to: "p/a.jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        XCTAssertEqual(index.summary(now: now, calendar: calendar).today.billableTokens, 7, "a file rewritten to the same size is read again")

        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(index.summary(now: now, calendar: calendar).totalTokens, 0, "a deleted file drops out")
    }

    func testMissingRootGivesSevenEmptyDays() {
        let summary = UsageAggregator.aggregate(root: root.appendingPathComponent("nope"), now: now, calendar: calendar)
        XCTAssertEqual(summary.days.count, 7)
        XCTAssertEqual(summary.totalTokens, 0)
    }

    func testFormatsCompactPtBR() {
        XCTAssertEqual(UsageFormat.tokens(0), "0")
        XCTAssertEqual(UsageFormat.tokens(950), "950")
        XCTAssertEqual(UsageFormat.tokens(1_000), "1 mil")
        XCTAssertEqual(UsageFormat.tokens(12_340), "12,3 mil")
        XCTAssertEqual(UsageFormat.tokens(139_532_001), "139,5 mi")
        XCTAssertEqual(UsageFormat.tokens(999_960), "1 mi")
        XCTAssertEqual(UsageFormat.tokens(1_234_000_000), "1,2 bi")
    }
}
