import XCTest
@testable import WispCore

final class EngineResumeTests: XCTestCase {
    func testACodexTurnNeverResumesAClaudeSessionId() {
        let plan = EngineResume.plan(kind: .codex, lastEngine: "claude", claudeSession: "claude-s", codexSession: nil, lost: false)
        XCTAssertNil(plan.resume)
        XCTAssertTrue(plan.prime)
        XCTAssertTrue(plan.switched)
        XCTAssertFalse(plan.dropClaudeSession)
        let again = EngineResume.plan(kind: .codex, lastEngine: "codex", claudeSession: "claude-s", codexSession: "thread-1", lost: false)
        XCTAssertEqual(again.resume, "thread-1")
        XCTAssertFalse(again.prime)
    }

    func testACodexOnlyConversationHasNoClaudeSessionAndAClaudeTurnRebuilds() {
        let plan = EngineResume.plan(kind: .claude, lastEngine: "codex", claudeSession: nil, codexSession: "thread-1", lost: false)
        XCTAssertNil(plan.resume)
        XCTAssertTrue(plan.prime && plan.switched && plan.dropClaudeSession)
        XCTAssertEqual(plan.linkReason, "rebuilt")
    }

    func testAClaudeTurnNeverResumesACodexThread() {
        let plan = EngineResume.plan(kind: .claude, lastEngine: "codex", claudeSession: "claude-s", codexSession: "thread-1", lost: false)
        XCTAssertNil(plan.resume)
        let same = EngineResume.plan(kind: .claude, lastEngine: "claude", claudeSession: "claude-s", codexSession: nil, lost: false)
        XCTAssertEqual(same.resume, "claude-s")
        XCTAssertFalse(same.prime)
    }

    func testNewConversationAndLostThreadCases() {
        let fresh = EngineResume.plan(kind: .codex, lastEngine: nil, claudeSession: nil, codexSession: nil, lost: false)
        XCTAssertNil(fresh.resume)
        XCTAssertFalse(fresh.prime)
        let lost = EngineResume.plan(kind: .codex, lastEngine: "codex", claudeSession: nil, codexSession: "thread-1", lost: true)
        XCTAssertNil(lost.resume)
        XCTAssertTrue(lost.prime)
    }

    func testHistoryOfACodexOnlyConversationComesFromTheTranscriptByConversationId() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-th-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptStore(folder: dir)
        let key = UUID().uuidString.lowercased()
        try store.appendUser(conversation: key, openingSession: nil, text: "oi", surface: "app")
        try store.appendAssistant(conversation: key, openingSession: nil, text: "ola", surface: "app", engine: "codex", model: "")
        let history = TranscriptHistory.load(store: store, sessionId: nil, conversationKey: key, claude: { _ in
            XCTFail("no Claude session to read")
            return nil
        })
        XCTAssertEqual(history?.map(\.text), ["oi", "ola"])
    }

    func testHistoryPrefersTheTranscriptOnceAnotherEngineAnswered() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-th-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TranscriptStore(folder: dir)
        try store.appendUser(conversation: "c1", openingSession: "s1", text: "oi", surface: "app")
        try store.appendAssistant(conversation: "c1", openingSession: nil, text: "ola", surface: "app", engine: "claude", model: "m")
        let claudeOnly = TranscriptHistory.load(store: store, sessionId: "s1", conversationKey: "zz", claude: { _ in
            [ConversationMessage(role: .assistant, text: "from claude file")]
        })
        XCTAssertEqual(claudeOnly?.map(\.text), ["from claude file"])
        try store.appendAssistant(conversation: "c1", openingSession: nil, text: "codex says", surface: "app", engine: "codex", model: "")
        let mixed = TranscriptHistory.load(store: store, sessionId: "s1", conversationKey: "zz", claude: { _ in
            XCTFail("Claude's file misses the Codex turns")
            return nil
        })
        XCTAssertEqual(mixed?.map(\.text), ["oi", "ola", "codex says"])
    }
}
