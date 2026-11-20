import XCTest
@testable import WispCore

final class ConversationTranscriptTests: XCTestCase {
    private static let session = "11111111-1111-4111-8111-111111111111"
    private static let rebuilt = "22222222-2222-4222-8222-222222222222"
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-conversas-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    private func contract(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("cli/tests/fixtures/contract/\(name)"), encoding: .utf8)
    }

    private func fixtureLines() throws -> [String] {
        try contract("conversation-transcript.jsonl").split(separator: "\n").map(String.init)
    }

    func testEveryFixtureLineIsTheCanonicalEncoding() throws {
        let data = Data(try contract("conversation-transcript.jsonl").utf8)
        let entries = ConversationTranscript.decode(data)
        let lines = try fixtureLines()
        XCTAssertEqual(entries.count, lines.count)
        XCTAssertEqual(try entries.map(ConversationTranscript.encode), lines)
    }

    func testTheWriterProducesTheFixtureByteForByte() throws {
        let stamps = StampQueue([
            "2026-11-20T12:00:01.000Z", "2026-11-20T12:00:09.250Z", "2026-11-20T12:05:00.000Z",
            "2026-11-20T12:05:07.000Z", "2026-11-20T12:05:30.000Z", "2026-11-20T12:06:00.000Z",
        ])
        let store = TranscriptStore(folder: folder, stamp: { stamps.next() })
        let id = Self.session
        try store.appendUser(
            conversation: id, openingSession: id,
            text: "Oi, tudo bem?\nQuero \"ajuda\" com o café e o link https://exemplo.com/a.", surface: "app")
        try store.appendAssistant(
            conversation: id, openingSession: id, text: "Claro! Em que posso ajudar?", surface: "app",
            engine: "claude", model: "claude-opus-4-8")
        try store.appendUser(conversation: id, openingSession: id, text: "E agora pelo celular", surface: "telegram")
        try store.appendAssistant(
            conversation: id, openingSession: id, text: "Continuamos aqui.", surface: "telegram",
            engine: "claude", model: "claude-opus-4-8")
        try store.appendUser(conversation: id, openingSession: id, text: "Separa\u{2028}linha\u{85}e\u{2029}fim", surface: "app")
        try store.link(session: Self.rebuilt, conversation: id, engine: "claude", reason: "rebuilt")
        let written = try String(contentsOf: folder.appendingPathComponent("\(id).jsonl"), encoding: .utf8)
        XCTAssertEqual(written.split(separator: "\n").map(String.init), try fixtureLines())
        XCTAssertEqual(
            store.entries(conversation: id).count, try fixtureLines().count)
        XCTAssertTrue(store.entries(conversation: id).contains { $0.text == "Separa\u{2028}linha\u{85}e\u{2029}fim" })
    }

    func testAUserMessageWithoutAReplyIsNotHistory() {
        XCTAssertNil(ConversationTranscript.context([TranscriptEntry(kind: .user, at: "", text: "primeira")]))
    }

    func testTheConversationsFolderIsPrivate() throws {
        try TranscriptStore(folder: folder.appendingPathComponent("conversas"))
            .appendUser(conversation: Self.session, openingSession: nil, text: "a", surface: "app")
        let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("conversas").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o700)
    }

    func testTheRebuiltContextIsTheFixtures() throws {
        let store = TranscriptStore(folder: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try contract("conversation-transcript.jsonl").write(
            to: folder.appendingPathComponent("\(Self.session).jsonl"), atomically: true, encoding: .utf8)
        XCTAssertEqual(store.context(conversation: Self.session), try contract("conversation-context.txt"))
    }

    func testOlderMessagesAreShortenedAndTheBudgetHolds() {
        let entries = (0..<40).map {
            TranscriptEntry(kind: $0 % 2 == 0 ? .user : .assistant, at: "", text: "\($0)" + String(repeating: "x", count: 5000))
        }
        let blocks = ConversationTranscript.context(entries)!.components(separatedBy: "\n\n")
        XCTAssertTrue(blocks[1].contains("older messages not shown"))
        let messages = blocks.filter { $0.hasPrefix("User: ") || $0.hasPrefix("Assistant: ") }
        XCTAssertEqual(messages.last!.unicodeScalars.count, "Assistant: ".count + ConversationTranscript.recentChars + 1)
        XCTAssertLessThanOrEqual(messages.first!.unicodeScalars.count, "Assistant: ".count + ConversationTranscript.olderChars + 1)
        XCTAssertLessThanOrEqual(blocks.joined(separator: "\n\n").unicodeScalars.count, ConversationTranscript.budgetChars + 600)
    }

    func testNoMessagesMeansNoContext() {
        XCTAssertNil(ConversationTranscript.context([]))
        XCTAssertNil(ConversationTranscript.context([TranscriptEntry(kind: .session, at: "", session: "x")]))
    }

    func testARelinkedSessionResolvesToTheSameConversation() throws {
        let store = TranscriptStore(folder: folder)
        let id = Self.session
        try store.appendUser(conversation: id, openingSession: id, text: "oi", surface: "app")
        try store.link(session: Self.rebuilt, conversation: id, engine: "claude", reason: "rebuilt")
        XCTAssertEqual(TranscriptStore(folder: folder).find(session: Self.rebuilt), id)
        XCTAssertNil(TranscriptStore(folder: folder).find(session: "33333333-3333-4333-8333-333333333333"))
    }

    func testAnAppConversationWithItsOwnIdIsFoundBySession() throws {
        let store = TranscriptStore(folder: folder)
        let app = "7f4c2b1e-0000-4000-8000-000000000001"
        try store.appendUser(conversation: app, openingSession: nil, text: "oi", surface: "app")
        try store.link(session: Self.session, conversation: app, engine: "claude", reason: "new")
        XCTAssertEqual(store.find(session: Self.session), app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(Self.session).jsonl").path))
    }

    func testTheContextOfAFailedResumeLeavesOutTheMessageBeingSent() throws {
        let store = TranscriptStore(folder: folder)
        let id = Self.session
        try store.appendUser(conversation: id, openingSession: id, text: "qual a capital da França?", surface: "telegram")
        try store.appendAssistant(
            conversation: id, openingSession: id, text: "Paris.", surface: "telegram", engine: "claude", model: "m")
        try store.appendUser(conversation: id, openingSession: id, text: "e a da Itália?", surface: "app")
        let context = try XCTUnwrap(store.context(conversation: id, dropTrailingUsers: 1))
        XCTAssertTrue(context.contains("User: qual a capital da França?"))
        XCTAssertTrue(context.contains("Assistant: Paris."))
        XCTAssertFalse(context.contains("Itália"))
        XCTAssertEqual(
            ConversationTranscript.prime(context, prompt: "e a da Itália?").suffix(14), "e a da Itália?")
    }

    func testTheClaudeErrorForAMissingSessionIsRecognised() {
        let line = #"{"type":"result","is_error":true,"errors":["No conversation found with session ID: abc"],"session_id":"abc"}"#
        guard case .result(_, let text, let isError, _)? = ClaudeStreamDecoder.decode(line: line).first else {
            return XCTFail("no result event")
        }
        XCTAssertTrue(isError)
        XCTAssertTrue(ConversationTranscript.isLostSession(text))
        XCTAssertFalse(ConversationTranscript.isLostSession("rate limit"))
    }

    func testConcurrentWritersNeverInterleaveALine() throws {
        let store = TranscriptStore(folder: folder)
        let id = Self.session
        let big = String(repeating: "y", count: 20000)
        DispatchQueue.concurrentPerform(iterations: 4) { writer in
            for turn in 0..<25 {
                try? TranscriptStore(folder: folder)
                    .appendUser(conversation: id, openingSession: id, text: "\(writer)-\(turn)-\(big)", surface: "app")
            }
        }
        let entries = store.entries(conversation: id)
        XCTAssertEqual(entries.filter { $0.kind == .user }.count, 100)
        let raw = try String(contentsOf: folder.appendingPathComponent("\(id).jsonl"), encoding: .utf8)
        XCTAssertEqual(raw.split(separator: "\n").count, entries.count)
    }

    func testABrokenLastLineDoesNotEatTheNextOne() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("\(Self.session).jsonl")
        try Data(#"{"kind":"user","text":"corta"#.utf8).write(to: path)
        try TranscriptStore(folder: folder)
            .appendUser(conversation: Self.session, openingSession: nil, text: "inteira", surface: "app")
        XCTAssertEqual(TranscriptStore(folder: folder).entries(conversation: Self.session).map(\.text), ["inteira"])
    }

    func testAnInvalidConversationIdIsRefused() {
        let store = TranscriptStore(folder: folder)
        XCTAssertThrowsError(try store.appendUser(conversation: "../x", openingSession: nil, text: "a", surface: "app"))
        XCTAssertThrowsError(try store.appendUser(conversation: "", openingSession: nil, text: "a", surface: "app"))
    }

    func testAWriteFailureThrowsInsteadOfCrashing() throws {
        try Data("arquivo".utf8).write(to: folder)
        XCTAssertThrowsError(
            try TranscriptStore(folder: folder)
                .appendUser(conversation: Self.session, openingSession: nil, text: "a", surface: "app"))
    }

    func testTheFolderComesFromWispJson() throws {
        let home = folder.appendingPathComponent("home")
        let config = home.appendingPathComponent(".config/wisp")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        XCTAssertEqual(WispFolder.conversations(environment: [:], home: home).path, home.path + "/Wisp/conversas")
        try Data(#"{"wisp_dir":"~/Meu Wisp"}"#.utf8).write(to: config.appendingPathComponent("wisp.json"))
        XCTAssertEqual(WispFolder.conversations(environment: [:], home: home).path, home.path + "/Meu Wisp/conversas")
        let elsewhere = folder.appendingPathComponent("outro.json")
        try Data(#"{"wisp_dir":"/abs/Wisp"}"#.utf8).write(to: elsewhere)
        XCTAssertEqual(
            WispFolder.conversations(environment: ["WISP_CONFIG": elsewhere.path], home: home).path, "/abs/Wisp/conversas")
    }
}

private final class StampQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String]

    init(_ items: [String]) { self.items = items }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        return items.isEmpty ? "" : items.removeFirst()
    }
}
