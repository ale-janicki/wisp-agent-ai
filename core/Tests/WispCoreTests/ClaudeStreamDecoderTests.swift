import Foundation
import XCTest
@testable import WispCore

final class ClaudeStreamDecoderTests: XCTestCase {
    private func fixtureEvents() throws -> [ClaudeEvent] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/two-turns", withExtension: "jsonl"))
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(separator: "\n").flatMap { ClaudeStreamDecoder.decode(line: String($0)) }
    }

    func testDecodesInit() throws {
        let events = try fixtureEvents()
        guard case let .initialized(sessionId, _, subscription)? = events.first(where: {
            if case .initialized = $0 { return true } else { return false }
        }) else { return XCTFail("no init event") }
        XCTAssertFalse(sessionId.isEmpty)
        XCTAssertTrue(subscription)
    }

    func testDecodesTextAndResult() throws {
        let events = try fixtureEvents()
        let results = events.compactMap { event -> String? in
            if case let .result(_, text, _, _) = event { return text }
            return nil
        }
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.first?.hasPrefix("um") == true)
        XCTAssertTrue(results.last?.hasPrefix("dois") == true)
        XCTAssertTrue(events.contains { if case .text = $0 { return true } else { return false } })
    }

    func testSameSessionAcrossTurns() throws {
        let ids = try fixtureEvents().compactMap { event -> String? in
            if case let .result(sessionId, _, _, _) = event { return sessionId }
            return nil
        }
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 1)
    }

    func testReplayedUserMessageIsTheEngineConsumingIt() {
        let echo = #"{"type":"user","uuid":"e6cb0441","isReplay":true,"message":{"role":"user","content":"dois"}}"#
        XCTAssertEqual(ClaudeStreamDecoder.decode(line: echo), [.userReplayed])
        let other = #"{"type":"user","uuid":"f865143a","message":{"role":"user","content":[{"type":"text","text":"x"}]}}"#
        XCTAssertEqual(ClaudeStreamDecoder.decode(line: other), [.ignored(type: "user")])
    }

    func testToolUseSummary() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}]}}"#
        XCTAssertEqual(ClaudeStreamDecoder.decode(line: line), [.toolUse(name: "Bash", summary: "ls -la")])
    }

    func testUnknownTypeIgnored() {
        XCTAssertEqual(ClaudeStreamDecoder.decode(line: #"{"type":"future_event"}"#), [.ignored(type: "future_event")])
    }

    func testNotJSONIsMalformed() {
        XCTAssertEqual(ClaudeStreamDecoder.decode(line: "not json"), [.malformed("not json")])
    }

    func testUsageFiveHour() throws {
        let usage = try fixtureEvents().compactMap { event -> Double? in
            if case let .usage(rateLimit) = event { return rateLimit.fiveHour?.utilization }
            return nil
        }
        XCTAssertEqual(usage, [0.06])
    }

    func testUsageSevenDayAndResets() throws {
        let limits = try fixtureEvents().compactMap { event -> RateLimit? in
            if case let .usage(rateLimit) = event { return rateLimit }
            return nil
        }
        let limit = try XCTUnwrap(limits.first)
        XCTAssertEqual(limit.fiveHour?.resetsAt, Date(timeIntervalSince1970: 1_794_861_000))
        XCTAssertEqual(limit.sevenDay?.utilization, 0.11)
        XCTAssertEqual(limit.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1_795_122_000))
    }

    func testMultiItemLineKeepsOrder() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"h"},{"type":"text","text":"oi"},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#
        XCTAssertEqual(ClaudeStreamDecoder.decode(line: line), [.thinking, .text("oi"), .toolUse(name: "Bash", summary: "ls")])
    }

    func testToolUseSummaryTruncatesPtBR() throws {
        let original = String(repeating: "ação é ótima ", count: 10).prefix(120)
        let input = try JSONSerialization.data(withJSONObject: ["command": String(original)])
        let inputText = try XCTUnwrap(String(data: input, encoding: .utf8))
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":"# + inputText + #"}]}}"#
        guard case let .toolUse(_, summary)? = ClaudeStreamDecoder.decode(line: line).first else { return XCTFail("no toolUse") }
        XCTAssertEqual(summary.count, 80)
        XCTAssertTrue(original.hasPrefix(summary))
    }

    func testResultErrorWithoutText() {
        let line = #"{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"s"}"#
        XCTAssertEqual(ClaudeStreamDecoder.decode(line: line), [.result(sessionId: "s", text: "", isError: true, denials: [])])
    }

    func testUsageWithoutFiveHour() {
        let line = #"{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{}}}"#
        XCTAssertEqual(ClaudeStreamDecoder.decode(line: line), [.usage(RateLimit())])
    }

    func testUnknownContentItemIgnored() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"tool_result","content":"x"}]}}"#
        XCTAssertEqual(ClaudeStreamDecoder.decode(line: line), [.ignored(type: "assistant.tool_result")])
    }
}
