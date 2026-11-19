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

    func testParsesStatusAndShared() throws {
        XCTAssertEqual(
            try TelegramTopics.parseStatus(Data(#"{"up": true, "host": "mac", "state": "active", "age_s": 2}"#.utf8)),
            TelegramStatus(up: true, host: "mac", state: "active")
        )
        XCTAssertFalse(try TelegramTopics.parseStatus(Data(#"{"up": false, "host": "mac", "state": null, "age_s": null}"#.utf8)).up)
        let shared = try TelegramTopics.parseShared(Data(#"{"thread": 77, "session_id": "s-77", "name": "oi"}"#.utf8))
        XCTAssertEqual(shared, TelegramShared(thread: 77, name: "oi", sessionId: "s-77"))
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

    func testSectionsFollowTheSessionNotTheStoredThread() {
        let shared = ConversationRecord(id: UUID(), sessionId: "s-9", title: "a", updatedAt: Date(timeIntervalSince1970: 2))
        let older = ConversationRecord(id: UUID(), sessionId: "s-9", title: "a", updatedAt: Date(timeIntervalSince1970: 1))
        let staleThread = ConversationRecord(id: UUID(), sessionId: "s-5", title: "b", updatedAt: Date(), telegramThread: 5)
        let local = ConversationRecord(id: UUID(), sessionId: "s-1", title: "c", updatedAt: Date())
        let blank = ConversationRecord(id: UUID(), sessionId: nil, title: "d", updatedAt: Date())
        let topics = [
            TelegramTopic(thread: 9, name: "a", sessionId: "s-9", cwd: "/"),
            TelegramTopic(thread: 3, name: "bot", sessionId: "s-3", cwd: "/"),
        ]

        let sections = TelegramTopics.sections(records: [shared, older, staleThread, local, blank], topics: topics)
        XCTAssertEqual(sections.wisp.map(\.id), [staleThread.id, local.id, blank.id])
        XCTAssertEqual(sections.telegram.map(\.id), [9, 3])
        XCTAssertEqual(sections.telegram[0].record?.id, shared.id)
        XCTAssertNil(sections.telegram[1].record)

        let unread = TelegramTopics.sections(records: [shared, local], topics: nil)
        XCTAssertEqual(unread.wisp.map(\.id), [shared.id, local.id])
        XCTAssertTrue(unread.telegram.isEmpty)
    }

    func testSharingMovesAConversationBetweenSectionsWithoutCopyingIt() {
        let record = ConversationRecord(id: UUID(), sessionId: "s-1", title: "c", updatedAt: Date())
        let before = TelegramTopics.sections(records: [record], topics: [])
        XCTAssertEqual(before.wisp.map(\.id), [record.id])
        XCTAssertTrue(before.telegram.isEmpty)
        let topic = TelegramTopic(thread: 4, name: "c", sessionId: "s-1", cwd: "/")
        let after = TelegramTopics.sections(records: [record], topics: [topic])
        XCTAssertTrue(after.wisp.isEmpty)
        XCTAssertEqual(after.telegram.map(\.id), [4])
        XCTAssertEqual(after.telegram[0].record?.id, record.id)
        XCTAssertEqual(TelegramTopics.topic(forSession: "s-1", in: [topic])?.thread, 4)
        XCTAssertNil(TelegramTopics.topic(forSession: "s-2", in: [topic]))
        XCTAssertNil(TelegramTopics.topic(forSession: nil, in: [topic]))
    }

    func testPostPayloadIsTheContractJSON() throws {
        let post = TelegramPost(thread: 12, user: "oi \"x\"", reply: "olá\nmundo")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: post.payload) as? [String: Any])
        XCTAssertEqual(object["thread"] as? Int, 12)
        XCTAssertEqual(object["user"] as? String, "oi \"x\"")
        XCTAssertEqual(object["reply"] as? String, "olá\nmundo")
        XCTAssertEqual(object.count, 3)
    }

    func testPostPayloadCarriesAttachmentPathsOnlyWhenThereAreSome() throws {
        let post = TelegramPost(thread: 12, user: "oi", reply: "ok", files: ["/tmp/a.png", "/tmp/b.pdf"])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: post.payload) as? [String: Any])
        XCTAssertEqual(object["arquivos"] as? [String], ["/tmp/a.png", "/tmp/b.pdf"])
        XCTAssertEqual(object.count, 4)
        let topics = [TelegramTopic(thread: 4, name: "c", sessionId: "s-1", cwd: "/")]
        XCTAssertEqual(TelegramTopics.mirror(sessionId: "s-1", topics: topics, user: "u", reply: "r", files: ["/x"])?.files, ["/x"])
    }

    func testAMirrorFollowsOnlyConversationsInTelegram() {
        let topics = [TelegramTopic(thread: 4, name: "c", sessionId: "s-1", cwd: "/")]
        XCTAssertEqual(
            TelegramTopics.mirror(sessionId: "s-1", topics: topics, user: "oi", reply: "olá"),
            TelegramPost(thread: 4, user: "oi", reply: "olá"))
        XCTAssertNil(TelegramTopics.mirror(sessionId: "s-2", topics: topics, user: "oi", reply: "olá"), "unshared stays local")
        XCTAssertNil(TelegramTopics.mirror(sessionId: nil, topics: topics, user: "oi", reply: "olá"))
        XCTAssertNil(TelegramTopics.mirror(sessionId: "s-1", topics: nil, user: "oi", reply: "olá"), "topics unread")
        XCTAssertNil(TelegramTopics.mirror(sessionId: "s-1", topics: topics, user: "oi", reply: " \n"), "no reply, nothing to post")
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
        let linked = ConversationRecord(id: UUID(), sessionId: "s-0", title: "g", updatedAt: Date())
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

    func testBlockNeedsReadAndCloseAndShareAndPostAreOptional() throws {
        XCTAssertTrue(TelegramBlock(status: "s", list: "l", close: "x").isComplete)
        XCTAssertFalse(TelegramBlock(status: "s", list: "l", close: "").isComplete)
        XCTAssertFalse(TelegramBlock().isComplete)
        let old = try JSONDecoder().decode(
            TelegramBlock.self, from: Data(#"{"status":"s","list":"l","create":"c","send":"m","close":"x","claim":"a"}"#.utf8))
        XCTAssertTrue(old.isComplete)
        XCTAssertFalse(old.canShare)
        XCTAssertFalse(old.canPost)
        let full = try JSONDecoder().decode(
            TelegramBlock.self, from: Data(#"{"status":"s","list":"l","share":"c {session}","post":"p","close":"x"}"#.utf8))
        XCTAssertTrue(full.canShare && full.canPost)
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

    func testTheTagsOfOldHistoryReadCleanly() {
        XCTAssertEqual(TelegramHTML.markdown("<strong>a</strong> <em>b</em> <s>c</s> <u>d</u>"), "**a** *b* ~~c~~ d")
        XCTAssertEqual(TelegramHTML.markdown("linha<br>outra<br/>fim"), "linha\noutra\nfim")
        XCTAssertEqual(TelegramHTML.markdown("<blockquote>citado\nem duas</blockquote>depois"), "> citado\n> em duasdepois")
        XCTAssertEqual(TelegramHTML.markdown("&lt;b&gt; &quot;x&quot; &amp; y"), "<b> \"x\" & y")
        XCTAssertEqual(
            TelegramHTML.markdown(#"<b>Slack:</b> <a href="https://a.dev/x?y=1&amp;z=2">doc</a> <code>a&lt;b</code>"#),
            "**Slack:** [doc](https://a.dev/x?y=1&z=2) `a<b`"
        )
    }

    func testMarkdownTheModelWroteItselfIsLeftAlone() {
        XCTAssertEqual(TelegramHTML.markdown("use `<b>x</b>` e <b>y</b>"), "use `<b>x</b>` e **y**")
        XCTAssertEqual(TelegramHTML.markdown("```html\n<i>a</i> &lt;\n```\n<i>b</i>"), "```html\n<i>a</i> &lt;\n```\n*b*")
        XCTAssertEqual(TelegramHTML.markdown("**sem html** a < b"), "**sem html** a < b")
    }
}

final class AgentInstructionsTests: XCTestCase {
    private func fixture(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("cli/tests/fixtures/contract/\(name)"), encoding: .utf8)
    }

    func testTelegramFilesInstructionMatchesTheBotsFixture() throws {
        XCTAssertEqual(AgentInstructions.telegramFiles, try fixture("telegram-files-instruction.txt"))
    }

    func testAppInstructionMatchesTheFixture() throws {
        XCTAssertEqual(AgentInstructions.appFiles, try fixture("app-files-instruction.txt"))
    }

    func testAnAppTurnInASharedTopicStillGetsTheAppInstructionPlusEnv() {
        let context = AgentInstructions.context(thread: 42, wispBinary: "/tmp/a b/bin/wisp")
        XCTAssertTrue(context.prompt.hasPrefix(AgentInstructions.appFiles))
        XCTAssertTrue(context.prompt.contains("file:///abs/path"))
        XCTAssertTrue(context.prompt.contains("also a Telegram topic"))
        XCTAssertTrue(context.prompt.contains("explicitly asks"))
        XCTAssertTrue(context.prompt.contains("topic enviar --thread=\"$WISP_TOPIC_THREAD\""))
        XCTAssertEqual(context.environment, ["WISP_BIN": "/tmp/a b/bin/wisp", "WISP_TOPIC_THREAD": "42"])
        XCTAssertEqual(context.thread, 42)
    }

    func testOutsideTelegramThereIsNoTelegramSendInstruction() {
        for context in [AgentInstructions.context(thread: nil, wispBinary: "/bin/wisp"),
                        AgentInstructions.context(thread: 7, wispBinary: nil)] {
            XCTAssertEqual(context.prompt, AgentInstructions.appFiles)
            XCTAssertTrue(context.environment.isEmpty)
            XCTAssertNil(context.thread)
        }
    }

    func testAppTextDoesNotSendFilesThroughTelegram() {
        XCTAssertFalse(AgentInstructions.appFiles.contains("files go only through"))
        XCTAssertFalse(AgentInstructions.appFiles.contains("topic enviar"))
        XCTAssertTrue(AgentInstructions.appFiles.contains("[name](file:///abs/path/name.ext)"))
    }

    func testBothTextsForbidTheTokenAndTheDirectApi() {
        for text in [AgentInstructions.appFiles, AgentInstructions.telegramFiles] {
            XCTAssertTrue(text.contains("Never call the Telegram API directly and never read the bot token"))
        }
    }

    func testWispBinaryComesFromTheListTemplateUnquoted() {
        XCTAssertEqual(TelegramBlock(list: "/opt/wisp topic listar --json").binary, "/opt/wisp")
        XCTAssertEqual(TelegramBlock(list: "'/tmp/a b/bin/wisp' topic listar --json").binary, "/tmp/a b/bin/wisp")
        XCTAssertEqual(TelegramBlock(list: "\"/tmp/a b/wisp\" topic listar --json").binary, "/tmp/a b/wisp")
        XCTAssertNil(TelegramBlock(list: "my-script list --json").binary)
        XCTAssertNil(TelegramBlock().binary)
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
    func testAttachmentsFolderDecodes() throws {
        let json = #"{"attachments":"~/.wisp-telegram/anexos"}"#
        let block = try JSONDecoder().decode(TelegramBlock.self, from: Data(json.utf8))
        XCTAssertEqual(block.attachments, "~/.wisp-telegram/anexos")
    }
}


final class TelegramBlockDerivationTests: XCTestCase {
    func testOldProfileGetsShareAndPostFromTheListCommand() {
        let block = TelegramBlock(status: "wisp status", list: "wisp topic listar --json", close: "wisp close")
        let derived = block.derivingActions()
        XCTAssertEqual(derived.share, "wisp topic compartilhar --session={session} --cwd={cwd} --nome={name} --json")
        XCTAssertEqual(derived.post, "wisp topic postar --json")
        XCTAssertTrue(derived.canShare && derived.canPost)
    }

    func testQuotedBinaryIsKeptVerbatim() {
        let block = TelegramBlock(list: "'/tmp/a b/bin/wisp' topic listar --json")
        let derived = block.derivingActions()
        XCTAssertEqual(derived.share, "'/tmp/a b/bin/wisp' topic compartilhar --session={session} --cwd={cwd} --nome={name} --json")
        XCTAssertEqual(derived.post, "'/tmp/a b/bin/wisp' topic postar --json")
    }

    func testCustomListCommandDerivesNothing() {
        let block = TelegramBlock(list: "my-script list --json")
        XCTAssertEqual(block.derivingActions(), block)
        XCTAssertFalse(block.derivingActions().canShare)
    }

    func testExistingShareAndPostAreNotOverwritten() {
        let block = TelegramBlock(list: "wisp topic listar --json", share: "mine {session}", post: "mine-post")
        XCTAssertEqual(block.derivingActions(), block)
    }
}

final class FileLinksTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("filelinks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func make(_ name: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return url.resolvingSymlinksInPath().path
    }

    private func paths(_ text: String) -> [String] { FileLinks.absolutePaths(in: text, home: dir.appendingPathComponent("home")) }

    func testCollectsExistingFilesInOrderAndDeduplicates() throws {
        let a = try make("a.pdf"), b = try make("b b.png")
        let text = "veja [a](file://\(a)) e [b](file://\(dir.path)/b%20b.png) e de novo [a](file://\(a))"
        XCTAssertEqual(paths(text).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }, [a, b])
    }

    func testIgnoresHttpMissingRelativeAndDirectories() throws {
        _ = try make("ok.txt")
        let text = "[x](https://example.com/a.pdf) [y](file://\(dir.path)/missing.txt) [z](file://relative/a.txt) [d](file://\(dir.path))"
        XCTAssertEqual(paths(text), [])
    }

    func testSkipsTheFoldersTheBotNeverSends() throws {
        let home = dir.appendingPathComponent("home")
        let ssh = home.appendingPathComponent(".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try Data("k".utf8).write(to: ssh.appendingPathComponent("id"))
        XCTAssertEqual(FileLinks.absolutePaths(in: "[k](file://\(ssh.path)/id)", home: home), [])
    }

    func testDenyListIgnoresCase() throws {
        let home = dir.appendingPathComponent("home")
        let ssh = home.appendingPathComponent(".ssh")
        let wisp = home.appendingPathComponent(".config/wisp")
        for folder in [ssh, wisp] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("k".utf8).write(to: folder.appendingPathComponent("id"))
        }
        for path in ["\(home.path)/.SSH/id", "\(home.path)/.Ssh/id", "\(home.path)/.Config/WISP/id", "\(home.path)/.config/Wisp/id"] {
            XCTAssertEqual(FileLinks.absolutePaths(in: "[k](file://\(path))", home: home), [], path)
        }
    }

    func testCapsAtTenFiles() throws {
        let text = try (0..<13).map { "[f](file://\(try make("f\($0).txt")))" }.joined(separator: " ")
        XCTAssertEqual(paths(text).count, FileLinks.maxFiles)
    }
}
