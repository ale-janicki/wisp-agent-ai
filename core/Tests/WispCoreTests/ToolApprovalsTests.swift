import XCTest
@testable import WispCore

final class ToolApprovalsTests: XCTestCase {
    private var directory: URL!
    private let id = String(repeating: "ab", count: 16)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-approvals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeRequest(_ id: String, thread: String = "null", created: Double = Date().timeIntervalSince1970) throws {
        let json = #"{"id":"\#(id)","tool":"email_send","summary":"enviar email","detail":"para: a@b.c","created":\#(created),"thread":\#(thread)}"#
        try json.write(to: directory.appendingPathComponent("\(id).json"), atomically: true, encoding: .utf8)
    }

    func testParsesRequestFile() throws {
        try writeRequest(id)
        try "{not json".write(to: directory.appendingPathComponent("\(String(repeating: "c", count: 32)).json"), atomically: true, encoding: .utf8)
        let pending = ToolApprovals(directory: directory).pending()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].toolName, "email_send")
        XCTAssertEqual(pending[0].summary, "enviar email")
        XCTAssertEqual(pending[0].detail, "para: a@b.c")
        XCTAssertTrue(pending[0].requiresExpansion)
        XCTAssertNil(pending[0].persistJSON)
        XCTAssertFalse(pending[0].canPersist)
    }

    func testHidesStaleRequests() throws {
        let fresh = String(repeating: "cd", count: 16)
        try writeRequest(id, created: 1_000)
        try writeRequest(fresh, created: 1_500)
        let approvals = ToolApprovals(directory: directory, now: { 1_000 + ToolApprovals.maxAge + 1 })
        XCTAssertEqual(approvals.pending().map(\.id), ["tool:\(fresh)"])
    }

    func testPendingSkipsAnsweredRequest() throws {
        try writeRequest(id)
        try "allow".write(to: directory.appendingPathComponent("\(id).decision"), atomically: true, encoding: .utf8)
        XCTAssertTrue(ToolApprovals(directory: directory).pending().isEmpty)
    }

    func testIdsArePrefixed() throws {
        try writeRequest(id)
        try writeRequest("NOT-A-VALID-ID")
        let pending = ToolApprovals(directory: directory).pending()
        XCTAssertEqual(pending.map(\.id), ["tool:\(id)"])
    }

    func testPendingIgnoresTombstones() throws {
        try writeRequest(id)
        let other = String(repeating: "cd", count: 16)
        try #"{"id":"\#(other)","outcome":"allow"}"#.write(to: directory.appendingPathComponent("\(other).done"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ToolApprovals(directory: directory).pending().map(\.id), ["tool:\(id)"])
    }

    func testDecideIsExclusive() throws {
        try writeRequest(id)
        let approvals = ToolApprovals(directory: directory)
        XCTAssertTrue(approvals.decide(id: "tool:\(id)", allow: true))
        XCTAssertFalse(approvals.decide(id: "tool:\(id)", allow: false))
        let text = try String(contentsOf: directory.appendingPathComponent("\(id).decision"), encoding: .utf8)
        XCTAssertEqual(text, "allow")
    }

    func testDecideAfterTheToolGaveUpIsRefusedAndLeavesNothing() throws {
        for outcome in ["expired", "cancelled"] {
            try writeRequest(id)
            try #"{"id":"\#(id)","outcome":"\#(outcome)"}"#.write(to: directory.appendingPathComponent("\(id).done"), atomically: true, encoding: .utf8)
            XCTAssertFalse(ToolApprovals(directory: directory).decide(id: "tool:\(id)", allow: true))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id).decision").path))
        }
    }

    func testDecideWhileTheToolPicksItUpStillCounts() throws {
        try writeRequest(id)
        try #"{"id":"\#(id)","outcome":"allow"}"#.write(to: directory.appendingPathComponent("\(id).done"), atomically: true, encoding: .utf8)
        XCTAssertTrue(ToolApprovals(directory: directory).decide(id: "tool:\(id)", allow: true))
    }

    func testIgnoresDecisionWithoutRequest() {
        let approvals = ToolApprovals(directory: directory)
        XCTAssertFalse(approvals.decide(id: "tool:\(id)", allow: true))
        XCTAssertFalse(approvals.decide(id: "tool:bad", allow: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(id).decision").path))
    }

    func testRefusesSymlinkedDirectory() throws {
        try writeRequest(id)
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-approvals-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        defer { try? FileManager.default.removeItem(at: link) }
        let approvals = ToolApprovals(directory: link)
        XCTAssertTrue(approvals.pending().isEmpty)
        XCTAssertFalse(approvals.decide(id: "tool:\(id)", allow: true))
    }
}
