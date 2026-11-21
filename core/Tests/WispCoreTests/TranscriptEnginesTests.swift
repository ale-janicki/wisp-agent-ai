import XCTest
@testable import WispCore

final class TranscriptEnginesTests: XCTestCase {
    private func store() throws -> (TranscriptStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-te-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (TranscriptStore(folder: dir), dir)
    }

    func testLastEngineAndEngineSessionFollowTheTranscript() throws {
        let (store, dir) = try store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = "conv-1"
        XCTAssertNil(store.lastEngine(conversation: id))
        try store.appendUser(conversation: id, openingSession: id, text: "oi", surface: "app")
        try store.appendAssistant(conversation: id, openingSession: nil, text: "ola", surface: "app", engine: "claude", model: "m")
        XCTAssertEqual(store.lastEngine(conversation: id), "claude")
        XCTAssertNil(store.engineSession(conversation: id, engine: "codex"))
        try store.link(session: "thread-1", conversation: id, engine: "codex", reason: "new")
        try store.appendAssistant(conversation: id, openingSession: nil, text: "ola do codex", surface: "telegram", engine: "codex", model: "")
        XCTAssertEqual(store.lastEngine(conversation: id), "codex")
        XCTAssertEqual(store.engineSession(conversation: id, engine: "codex"), "thread-1")
        XCTAssertEqual(store.engines(conversation: id), ["claude", "codex"])
        XCTAssertEqual(store.find(session: "thread-1"), id)
        XCTAssertEqual(store.messages(conversation: id).map(\.text), ["oi", "ola", "ola do codex"])
        XCTAssertEqual(store.messages(conversation: id).map(\.role), [.user, .assistant, .assistant])
    }

    func testSwitchNoteNamesTheEngine() {
        XCTAssertTrue(ConversationTranscript.switchedNote(to: .codex).contains("Codex"))
        XCTAssertTrue(ConversationTranscript.rebuiltNote(engine: .claude).contains("Claude"))
        XCTAssertEqual(ConversationTranscript.rebuiltNote(engine: .claude), ConversationTranscript.rebuiltNote)
    }
}
