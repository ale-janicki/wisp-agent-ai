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

    func testParsesTheReadingHostOfEveryTopic() throws {
        let json = #"""
        [{"thread": 6018, "name": "projeto-sync", "session_id": "s-6018", "cwd": "/Users/test", "started": true, "turns": 1, "last_used": 1794788722.3, "host": "pc", "session_host": "pc"},
         {"thread": 826, "name": "Alertas", "session_id": "s-826", "cwd": "/Users/test", "started": true, "turns": 2, "last_used": 1791983990.9, "host": null, "session_host": "mac"}]
        """#
        let topics = try TelegramTopics.parseTopics(Data(json.utf8))
        XCTAssertEqual(topics.map(\.thread), [6018, 826])
        XCTAssertEqual(topics[0].host, "pc")
        XCTAssertNil(topics[1].host)
        XCTAssertEqual(topics[1].turns, 2)
    }

    func testStatusSaysWhoReadsTelegram() throws {
        func reading(_ json: String) throws -> TelegramReading {
            try TelegramTopics.parseStatus(Data(json.utf8)).reading
        }
        XCTAssertEqual(try reading(#"{"up": true, "host": "mac", "state": "active", "age_s": 1, "reader": "mac"}"#), .here)
        XCTAssertEqual(try reading(#"{"up": false, "host": "mac", "state": "standby", "age_s": 3, "reader": "pc"}"#), .elsewhere("pc"))
        XCTAssertEqual(try reading(#"{"up": false, "host": "mac", "state": "standby", "age_s": 3, "reader": null}"#), .nobody)
        XCTAssertEqual(try reading(#"{"up": false, "host": "mac", "state": "standby", "age_s": 3, "reader": "mac"}"#), .nobody)
        XCTAssertEqual(try reading(#"{"up": true, "host": "mac", "state": "active", "age_s": 1}"#), .here)
        XCTAssertEqual(try reading(#"{"up": false, "host": "mac", "state": null, "age_s": null}"#), .nobody)
        XCTAssertEqual(TelegramTopics.hostName("pc"), "PC")
        XCTAssertEqual(TelegramTopics.hostName("mac"), "Mac")
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

    func testFixedTopicsParseAndPinFirstIncludingThreadZero() throws {
        let json = #"""
        [{"thread": 7, "name": "recent", "session_id": "s-7", "fixed": false},
         {"thread": 45, "name": "daily", "session_id": "s-45", "fixed": true},
         {"thread": 0, "name": "general", "session_id": "s-0", "fixed": true},
         {"thread": 3, "name": "old", "session_id": "s-3"}]
        """#
        let topics = try TelegramTopics.parseTopics(Data(json.utf8))
        XCTAssertEqual(topics.map(\.fixed), [false, true, true, false])
        let sections = TelegramTopics.sections(records: [], topics: topics)
        XCTAssertEqual(sections.telegram.map(\.id), [0, 45, 7, 3])
        let linked = ConversationRecord(id: UUID(), sessionId: "s-0", title: "g", updatedAt: Date(), telegramThread: 0)
        let withGeneral = TelegramTopics.sections(records: [linked], topics: topics)
        XCTAssertEqual(withGeneral.telegram[0].record?.id, linked.id)
        XCTAssertTrue(withGeneral.wisp.isEmpty)
    }

    private func orderTopics() -> [TelegramTopic] {
        [
            TelegramTopic(thread: 7, name: "recent", sessionId: "s-7", cwd: "/", lastUsed: Date(timeIntervalSince1970: 70)),
            TelegramTopic(thread: 45, name: "daily", sessionId: "s-45", cwd: "/", fixed: true),
            TelegramTopic(thread: 0, name: "general", sessionId: "s-0", cwd: "/", fixed: true),
            TelegramTopic(thread: 3, name: "old", sessionId: "s-3", cwd: "/", lastUsed: Date(timeIntervalSince1970: 30)),
        ]
    }

    func testNoSavedOrderKeepsTodaysOrder() {
        let sections = TelegramTopics.sections(records: [], topics: orderTopics(), order: [])
        XCTAssertEqual(sections.telegram.map(\.id), [0, 45, 7, 3])
    }

    func testSavedOrderIsApplied() {
        let sections = TelegramTopics.sections(records: [], topics: orderTopics(), order: [3, 7, 45, 0])
        XCTAssertEqual(sections.telegram.map(\.id), [3, 7, 45, 0])
    }

    func testThreadsNotInTheSavedOrderGoOnTopByLastUsed() {
        var topics = orderTopics()
        topics.append(TelegramTopic(thread: 11, name: "new", sessionId: "s-11", cwd: "/", lastUsed: Date(timeIntervalSince1970: 90)))
        topics.append(TelegramTopic(thread: 12, name: "newer", sessionId: "s-12", cwd: "/", lastUsed: Date(timeIntervalSince1970: 95)))
        let sections = TelegramTopics.sections(records: [], topics: topics, order: [3, 7, 45, 0])
        XCTAssertEqual(sections.telegram.map(\.id), [12, 11, 3, 7, 45, 0])
    }

    func testUnknownIdsInTheSavedOrderAreIgnored() {
        let sections = TelegramTopics.sections(records: [], topics: orderTopics(), order: [99, 3, 98, 0])
        XCTAssertEqual(sections.telegram.map(\.id), [7, 45, 3, 0])
    }

    func testSavedTelegramOrderRoundTripsAndOldSettingsStillLoad() throws {
        let old = try JSONDecoder().decode(WispSettings.self, from: Data(#"{"theme":"lime"}"#.utf8))
        XCTAssertEqual(old.telegramOrder, [])
        var settings = WispSettings()
        settings.telegramOrder = [5, 0, 9]
        let back = try JSONDecoder().decode(WispSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back.telegramOrder, [5, 0, 9])
    }

    func testParsesTheClaimAndItsFailureSentence() throws {
        XCTAssertEqual(
            try TelegramTopics.parseClaim(Data(#"{"ok": true, "reader": "mac", "waited_s": 7.4, "session": "trazida"}"#.utf8)),
            TelegramClaim(ok: true, reader: "mac", waitedSeconds: 7.4)
        )
        XCTAssertFalse(try TelegramTopics.parseClaim(Data(#"{"ok": false}"#.utf8)).ok)
        XCTAssertThrowsError(try TelegramTopics.parseClaim(Data("mac le o Telegram".utf8)))
        XCTAssertEqual(
            TelegramTopics.claimFailure("some-topic-tool: nao consegui falar com o PC (ssh); a mensagem nao foi enviada"),
            "nao consegui falar com o PC (ssh); a mensagem nao foi enviada"
        )
        XCTAssertEqual(TelegramTopics.claimFailure("o comando passou de 75 s"), "o comando passou de 75 s")
        XCTAssertEqual(TelegramTopics.claimFailure("aviso: a outra maquina nao respondeu"), "aviso: a outra maquina nao respondeu")
    }

    func testClaimNeedFollowsTheReaderAndTheLastClaim() throws {
        func need(_ json: String) throws -> TelegramClaimNeed {
            try TelegramTopics.parseStatus(Data(json.utf8)).claimNeed
        }
        XCTAssertEqual(try need(#"{"up": false, "host": "mac", "reader": "pc", "claim": "pc"}"#), .handOff("pc"))
        XCTAssertEqual(try need(#"{"up": true, "host": "mac", "reader": "mac", "claim": "mac"}"#), .none)
        XCTAssertEqual(try need(#"{"up": true, "host": "mac", "reader": "mac", "claim": "pc"}"#), .refresh)
        XCTAssertEqual(try need(#"{"up": true, "host": "mac", "reader": "mac", "claim": "none"}"#), .refresh)
        XCTAssertEqual(try need(#"{"up": true, "host": "mac", "reader": "mac", "claim": null}"#), .refresh)
        XCTAssertEqual(try need(#"{"up": true, "host": "mac", "reader": "mac"}"#), .refresh)
        XCTAssertEqual(try need(#"{"up": false, "host": "mac", "reader": null, "claim": "pc"}"#), .none)
        XCTAssertEqual(try need(#"{"up": true, "reader": "mac", "claim": "pc"}"#), .none)
    }

    func testClaimIsOptionalInTheBlock() throws {
        let json = #"{"status": "s", "list": "l", "create": "c", "send": "m", "close": "x"}"#
        let block = try JSONDecoder().decode(TelegramBlock.self, from: Data(json.utf8))
        XCTAssertTrue(block.isComplete)
        XCTAssertNil(block.claim)
        let withClaim = try JSONDecoder().decode(
            TelegramBlock.self,
            from: Data(#"{"status": "s", "list": "l", "create": "c", "send": "m", "close": "x", "claim": "a {thread}"}"#.utf8)
        )
        XCTAssertEqual(withClaim.claim, "a {thread}")
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

final class TelegramAttachmentsBlockTests: XCTestCase {
    func testAttachmentsFolderAndSendTemplateDecode() throws {
        let json = #"{"send":"x {anexos} -- {thread} {text}","attachments":"~/.Wisp-telegram/anexos"}"#
        let block = try JSONDecoder().decode(TelegramBlock.self, from: Data(json.utf8))
        XCTAssertEqual(block.attachments, "~/.Wisp-telegram/anexos")
        XCTAssertTrue(block.sendsAttachments)
        XCTAssertFalse(TelegramBlock(send: "x -- {thread} {text}").sendsAttachments)
    }
}
