import XCTest
@testable import WispCore

final class TelegramTopicsTests: XCTestCase {
    func testParsesTopicsFromTheCLIShape() throws {
        let json = #"""
        [{"thread": 9, "name": "recente", "session_id": "s-9", "cwd": "/Users/test/x", "started": true, "turns": 5, "last_used": 1700000000.5},
         {"thread": 8, "name": "novo", "session_id": "s-8", "cwd": "/Users/test", "started": false, "turns": 0, "last_used": null}]
        """#
        let topics = try TelegramTopics.parseTopics(Data(json.utf8))
        XCTAssertEqual(topics, [
            TelegramTopic(thread: 9, name: "recente", sessionId: "s-9", cwd: "/Users/test/x", turns: 5,
                          lastUsed: Date(timeIntervalSince1970: 1_700_000_000.5)),
            TelegramTopic(thread: 8, name: "novo", sessionId: "s-8", cwd: "/Users/test", turns: 0, lastUsed: nil),
        ])
    }

    func testGarbageIsAnError() {
        XCTAssertThrowsError(try TelegramTopics.parseTopics(Data("lendo o Telegram: mac".utf8)))
        XCTAssertThrowsError(try TelegramTopics.parseTopics(Data(#"[{"thread": "x"}]"#.utf8)))
    }

    func testParsesStatusAndCreated() throws {
        XCTAssertEqual(
            try TelegramTopics.parseStatus(Data(#"{"up": true, "host": "mac", "state": "active", "age_s": 2}"#.utf8)),
            TelegramStatus(up: true, host: "mac", state: "active")
        )
        XCTAssertFalse(try TelegramTopics.parseStatus(Data(#"{"up": false, "host": "mac", "state": null, "age_s": null}"#.utf8)).up)
        let created = try TelegramTopics.parseCreated(Data(#"{"thread": 77, "session_id": "s-77", "cwd": "/Users/test", "name": "oi"}"#.utf8))
        XCTAssertEqual(created.thread, 77)
        XCTAssertEqual(created.sessionId, "s-77")
        XCTAssertEqual(created.cwd, "/Users/test")
    }

    func testTopicNameIsTheFirstMessageOnOneLineCutAt40() {
        XCTAssertEqual(TelegramTopics.topicName(from: "  responda só:\n ok  "), "responda só: ok")
        let long = TelegramTopics.topicName(from: String(repeating: "abcde ", count: 20))
        XCTAssertEqual(long.count, 40)
        XCTAssertTrue(long.hasSuffix("…"))
    }

    func testLinkedConversationShowsOnceAsItsTopic() {
        let linked = ConversationRecord(id: UUID(), sessionId: "s-9", title: "a", updatedAt: Date(timeIntervalSince1970: 2), telegramThread: 9)
        let older = ConversationRecord(id: UUID(), sessionId: "s-9", title: "a", updatedAt: Date(timeIntervalSince1970: 1), telegramThread: 9)
        let closed = ConversationRecord(id: UUID(), sessionId: "s-5", title: "b", updatedAt: Date(), telegramThread: 5)
        let local = ConversationRecord(id: UUID(), sessionId: "s-1", title: "c", updatedAt: Date())
        let topics = [
            TelegramTopic(thread: 9, name: "a", sessionId: "s-9", cwd: "/"),
            TelegramTopic(thread: 3, name: "bot", sessionId: "s-3", cwd: "/"),
        ]

        let sections = TelegramTopics.sections(records: [linked, older, closed, local], topics: topics)
        XCTAssertEqual(sections.wisp.map(\.id), [closed.id, local.id])
        XCTAssertEqual(sections.telegram.map(\.id), [9, 3])
        XCTAssertEqual(sections.telegram[0].record?.id, linked.id)
        XCTAssertNil(sections.telegram[1].record)

        let unread = TelegramTopics.sections(records: [linked, local], topics: nil)
        XCTAssertEqual(unread.wisp.map(\.id), [linked.id, local.id])
        XCTAssertTrue(unread.telegram.isEmpty)
    }

    func testBlockIsCompleteOnlyWithEveryCommand() {
        XCTAssertTrue(TelegramBlock(status: "s", list: "l", create: "c", send: "m", close: "x").isComplete)
        XCTAssertFalse(TelegramBlock(status: "s", list: "l", create: "c", send: "", close: "x").isComplete)
        XCTAssertFalse(TelegramBlock().isComplete)
    }

    func testRecordWithoutLinkFieldsStillDecodesAndLinkRoundTrips() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = #"[{"id":"7F1C2E4A-0000-4000-8000-000000000001","sessionId":"s","title":"t","updatedAt":"2026-11-16T12:00:00.000Z"}]"#
        try Data(old.utf8).write(to: directory.appendingPathComponent("conversations.json"))
        let store = ConversationStore(directory: directory)
        XCTAssertNil(store.lastRecoveryNote)
        XCTAssertNil(store.all().first?.telegramThread)

        var record = try XCTUnwrap(store.all().first)
        record.telegramThread = 77
        record.cwd = "/Users/test"
        try store.upsert(record)
        let reread = ConversationStore(directory: directory).all().first
        XCTAssertEqual(reread?.telegramThread, 77)
        XCTAssertEqual(reread?.cwd, "/Users/test")
    }
}

final class TelegramHTMLTests: XCTestCase {
    func testKnownTagsBecomeInlineMarkdown() {
        XCTAssertEqual(
            TelegramHTML.markdown(#"<b>Feito</b>: <i>ok</i> em <code>a.swift</code> · <a href="https://x.dev/p">link</a> <u>u</u>"#),
            "**Feito**: *ok* em `a.swift` · [link](https://x.dev/p) u"
        )
        XCTAssertEqual(TelegramHTML.markdown("<pre>let a = 1\nlet b = 2</pre>"), "```\nlet a = 1\nlet b = 2\n```")
        XCTAssertEqual(TelegramHTML.markdown("1 &lt; 2 &amp;&amp; &amp;lt;"), "1 < 2 && &lt;")
        XCTAssertEqual(TelegramHTML.markdown("**já markdown** e <tag desconhecida>"), "**já markdown** e <tag desconhecida>")
    }
}

final class TranscriptParserTests: XCTestCase {
    private func user(_ text: String) -> String {
        let encoded = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
        return #"{"type":"user","message":{"role":"user","content":\#(encoded)}}"#
    }

    private func assistant(_ text: String, stop: String = "end_turn") -> String {
        let encoded = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
        return #"{"type":"assistant","message":{"role":"assistant","stop_reason":"\#(stop)","content":[{"type":"text","text":\#(encoded)}]}}"#
    }

    private let toolUse = #"{"type":"assistant","message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","id":"t","input":{}}]}}"#
    private let toolResult = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"x"}]}}"#

    func testSlugMatchesTheBotPerUnicodeScalar() {
        XCTAssertEqual(TranscriptReader.projectDirectoryName(forCwd: "/Users/test/Documents/brain"), "-Users-test-Documents-brain")
        XCTAssertEqual(TranscriptReader.projectDirectoryName(forCwd: "/Users/test/my_app.v2"), "-Users-test-my-app-v2")
        XCTAssertEqual(TranscriptReader.projectDirectoryName(forCwd: "/x/ação"), "-x-a--o")
        XCTAssertEqual(TranscriptReader.projectDirectoryName(forCwd: "/x/c\u{0327}"), "-x-c-")
        XCTAssertEqual(TranscriptReader.projectDirectoryName(forCwd: "/x/😀"), "-x--")
    }

    func testHalfWrittenLineWaitsForItsNewline() {
        var parser = TranscriptParser(statusPrefix: nil)
        let line = user("oi") + "\n"
        let bytes = Data(line.utf8)
        parser.consume(bytes.prefix(10))
        XCTAssertEqual(parser.snapshot.prompts, 0)
        parser.consume(bytes.dropFirst(10))
        XCTAssertEqual(parser.snapshot.messages.map(\.text), ["oi"])
        XCTAssertEqual(parser.snapshot.prompts, 1)
        XCTAssertTrue(parser.snapshot.turnOpen)
    }

    func testTurnStaysOpenThroughToolsAndClosesOnEndTurn() {
        var parser = TranscriptParser(statusPrefix: "STATUS ·")
        parser.consume(Data((user("faz") + "\n" + toolUse + "\n" + toolResult + "\n").utf8))
        XCTAssertTrue(parser.snapshot.turnOpen)
        XCTAssertEqual(parser.snapshot.messages.map(\.role), [.user])
        let idBefore = parser.snapshot.messages.count
        parser.consume(Data((assistant("feito\n\nSTATUS · x · ok") + "\n").utf8))
        let snap = parser.snapshot
        XCTAssertFalse(snap.turnOpen)
        XCTAssertEqual(snap.messages.map(\.text), ["faz", "feito"])
        XCTAssertEqual(snap.status, "x · ok")
        XCTAssertEqual(idBefore, 1)
        XCTAssertEqual(parser.snapshot.messages.last?.id, snap.messages.last?.id)
    }

    func testBotRuleTurnIsHiddenAndContextWrapperUnwrapped() {
        let lines = [
            user("[contexto do bot] Este topico ja tem historia. Leia a nota.\n\nMensagem do Ale:\nqual o saldo?"),
            assistant("<b>R$ 10</b>"),
            user("[regra do topico] O turno anterior fechou sem reescrever. Responda so \"ok\"."),
            assistant("ok"),
            user("valeu"),
        ].joined(separator: "\n")
        var parser = TranscriptParser(statusPrefix: nil, telegramHTML: true)
        parser.consume(Data(lines.utf8))
        parser.finish()
        XCTAssertEqual(parser.snapshot.messages.map(\.text), ["qual o saldo?", "**R$ 10**", "valeu"])
        XCTAssertEqual(parser.snapshot.prompts, 2)
    }
}

final class TranscriptFollowerTests: XCTestCase {
    func testFollowsAFileThatAppearsLaterAndGrows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent(TranscriptReader.projectDirectoryName(forCwd: "/Users/test"))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("s1.jsonl")

        let empty = expectation(description: "no file yet")
        let prompt = expectation(description: "prompt read")
        let reply = expectation(description: "reply read")
        let seen = Locked<[TranscriptParser.Snapshot]>([])
        let follower = TranscriptFollower(sessionId: "s1", cwd: "/Users/test", statusPrefix: nil, telegramHTML: false, projectsRoot: root) { snap in
            let count = seen.mutate { $0.append(snap); return $0.count }
            if count == 1 { empty.fulfill() }
            if snap.prompts == 1, snap.turnOpen { prompt.fulfill() }
            if snap.prompts == 1, !snap.turnOpen { reply.fulfill() }
        }
        follower.start()
        defer { follower.stop() }
        wait(for: [empty], timeout: 3)

        try Data((#"{"type":"user","message":{"role":"user","content":"oi"}}"# + "\n").utf8).write(to: file)
        wait(for: [prompt], timeout: 3)

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((#"{"type":"assistant","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"ok"}]}}"# + "\n").utf8))
        try handle.close()
        wait(for: [reply], timeout: 3)
        XCTAssertEqual(seen.mutate { $0.last?.messages.map(\.text) }, ["oi", "ok"])
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func mutate<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&value) } }
}
