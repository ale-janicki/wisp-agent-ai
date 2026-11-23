import XCTest
@testable import WispCore

final class OneConversationTests: XCTestCase {
    private let geral = UUID(uuidString: "62A355B9-ED36-4E9B-8125-D36308E7CBF9")!
    private let day = Date(timeIntervalSince1970: 1_795_000_000)

    private func record(_ id: UUID, session: String?, title: String = "Geral", at: Double = 0) -> ConversationRecord {
        ConversationRecord(id: id, sessionId: session, title: title, updatedAt: day.addingTimeInterval(at))
    }

    private func topic(session: String, conversation: String?, thread: Int = 0) -> TelegramTopic {
        TelegramTopic(thread: thread, name: "Geral", sessionId: session, cwd: "~", turns: 3, fixed: true, conversation: conversation)
    }

    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-one-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testTopicParsesTheConversationAndLowercasesIt() throws {
        let json = #"[{"thread": 0, "name": "Geral", "session_id": "s-1", "conversation": "62A355B9-ED36-4E9B-8125-D36308E7CBF9"}]"#
        let parsed = try TelegramTopics.parseTopics(Data(json.utf8))
        XCTAssertEqual(parsed.first?.conversation, "62a355b9-ed36-4e9b-8125-d36308e7cbf9")
        let legacy = try TelegramTopics.parseTopics(Data(#"[{"thread": 1, "name": "x", "session_id": "s"}]"#.utf8))
        XCTAssertNil(legacy.first?.conversation)
    }

    func testTheLinkSurvivesASessionIdChangeOnEitherSide() {
        let key = geral.uuidString.lowercased()
        let sections = TelegramTopics.sections(
            records: [record(geral, session: "old-session")], topics: [topic(session: "new-session", conversation: key)])
        XCTAssertTrue(sections.wisp.isEmpty)
        XCTAssertEqual(sections.telegram.first?.record?.id, geral)
        let mirrored = TelegramTopics.mirror(
            sessionId: "old-session", conversation: geral, topics: [topic(session: "new-session", conversation: key)],
            user: "oi", reply: "ola")
        XCTAssertEqual(mirrored?.thread, 0)
        XCTAssertEqual(mirrored?.conversation, key)
    }

    func testALegacyTopicWithoutConversationStillLinksBySession() {
        let sections = TelegramTopics.sections(
            records: [record(geral, session: "s-1")], topics: [topic(session: "s-1", conversation: nil)])
        XCTAssertTrue(sections.wisp.isEmpty)
        XCTAssertEqual(sections.telegram.first?.record?.id, geral)
    }

    func testAnUnrelatedConversationStaysLocal() {
        let other = UUID()
        let sections = TelegramTopics.sections(
            records: [record(geral, session: "a"), record(other, session: "b", title: "outra")],
            topics: [topic(session: "c", conversation: geral.uuidString.lowercased())])
        XCTAssertEqual(sections.wisp.map(\.id), [other])
    }

    func testClosedConversationsAreNeverListed() {
        let closedLocal = UUID()
        let closedLinked = UUID()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        var a = record(closedLocal, session: "x", title: "encerrada-a")
        a.closedAt = when
        var b = record(closedLinked, session: "s-1", title: "encerrada-b")
        b.closedAt = when.addingTimeInterval(60)
        let open = UUID()
        let sections = TelegramTopics.sections(
            allRecords: [a, b, record(open, session: "o", title: "aberta")],
            topics: [topic(session: "s-1", conversation: closedLinked.uuidString.lowercased())])
        XCTAssertEqual(sections.wisp.map(\.id), [open])
        XCTAssertNil(sections.telegram.first?.record)
    }

    func testClosedConversationsAreNeverListedWithoutTopics() {
        var a = record(geral, session: "x")
        a.closedAt = Date()
        let sections = TelegramTopics.sections(allRecords: [a], topics: nil)
        XCTAssertTrue(sections.wisp.isEmpty)
    }

    func testPinnedConversationsComeFirstInPinOrderAndTheRestKeepsItsOrder() {
        let ids = (0..<4).map { _ in UUID() }
        let records = ids.map { record($0, session: "s-\($0)", title: $0.uuidString) }
        let pins = [TelegramTopics.pinKey(conversation: ids[2]), "gone", TelegramTopics.pinKey(conversation: ids[0])]
        let sections = TelegramTopics.sections(records: records, topics: nil, pins: pins)
        XCTAssertEqual(sections.wisp.map(\.id), [ids[2], ids[0], ids[1], ids[3]])
    }

    func testPinsAreIgnoredForClosedAndMissingConversations() {
        let open = UUID()
        var closed = record(geral, session: "x")
        closed.closedAt = Date()
        let sections = TelegramTopics.sections(
            allRecords: [record(open, session: "o"), closed], topics: nil,
            pins: [TelegramTopics.pinKey(conversation: geral), TelegramTopics.pinKey(conversation: UUID())])
        XCTAssertEqual(sections.wisp.map(\.id), [open])
    }

    func testPinnedTopicsGoFirstInsideTelegramByThreadAndKeepTheSavedOrder() {
        let topics = [3, 7, 9, 12].map {
            TelegramTopic(thread: $0, name: "t\($0)", sessionId: "s-\($0)", cwd: "/", fixed: false)
        }
        let sections = TelegramTopics.sections(
            records: [], topics: topics, order: [3, 7, 9, 12],
            pins: [TelegramTopics.pinKey(thread: 12), TelegramTopics.pinKey(thread: 7), TelegramTopics.pinKey(thread: 99)])
        XCTAssertEqual(sections.telegram.map(\.id), [12, 7, 3, 9])
    }

    private func tg(_ threads: Int...) -> [String] { threads.map { TelegramTopics.pinKey(thread: $0) } }

    func testDraggingUnpinnedRowsKeepsPinnedIdsWhereTheyWereInTheSavedOrder() {
        // saved order 3,7,9,12 with 7 pinned: shown 7 | 3,9,12; drag 12 to the front of the unpinned block.
        let result = TelegramTopics.applyDrag(
            shown: [7, 3, 9, 12], final: [7, 12, 3, 9], pinnedCount: 1, order: [3, 7, 9, 12], pins: tg(7))
        XCTAssertEqual(result?.order, [12, 7, 3, 9])
        XCTAssertEqual(result?.pins, tg(7))
    }

    func testUnpinningReturnsARowToItsSavedSlot() {
        let order = [3, 7, 9, 12]
        let topics = [3, 7, 9, 12].map { TelegramTopic(thread: $0, name: "t\($0)", sessionId: "s-\($0)", cwd: "/", fixed: false) }
        let pinned = TelegramTopics.sections(records: [], topics: topics, order: order, pins: tg(9))
        XCTAssertEqual(pinned.telegram.map(\.id), [9, 3, 7, 12])
        let unpinned = TelegramTopics.sections(records: [], topics: topics, order: order, pins: [])
        XCTAssertEqual(unpinned.telegram.map(\.id), [3, 7, 9, 12])
    }

    func testDraggingPinnedRowsReordersOnlyThePins() {
        let result = TelegramTopics.applyDrag(
            shown: [7, 12, 3, 9], final: [12, 7, 3, 9], pinnedCount: 2, order: [3, 7, 9, 12], pins: [geral.uuidString.lowercased()] + tg(7, 12))
        XCTAssertEqual(result?.pins, [geral.uuidString.lowercased()] + tg(12, 7))
        XCTAssertEqual(result?.order, [3, 7, 9, 12])
    }

    func testADropAcrossThePinnedBoundaryChangesNothing() {
        XCTAssertNil(TelegramTopics.applyDrag(
            shown: [7, 3, 9], final: [3, 7, 9], pinnedCount: 1, order: [3, 7, 9], pins: tg(7)))
        XCTAssertNil(TelegramTopics.applyDrag(
            shown: [7, 3, 9], final: [7, 3, 9], pinnedCount: 1, order: [3, 7, 9], pins: tg(7)))
    }

    func testPinsRoundTripAndOldSettingsDefaultToNone() throws {
        let old = try JSONDecoder().decode(WispSettings.self, from: Data(#"{"theme":"lime"}"#.utf8))
        XCTAssertEqual(old.pinnedConversations, [])
        var settings = WispSettings()
        settings.pinnedConversations = ["tg:5", geral.uuidString.lowercased()]
        let back = try JSONDecoder().decode(WispSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back.pinnedConversations, ["tg:5", geral.uuidString.lowercased()])
    }

    func testPostPayloadCarriesTheConversationOnlyWhenKnown() throws {
        let with = TelegramPost(thread: 4, user: "u", reply: "r", conversation: "abc")
        let body = try JSONSerialization.jsonObject(with: with.payload) as? [String: Any]
        XCTAssertEqual(body?["conversation"] as? String, "abc")
        let without = try JSONSerialization.jsonObject(with: TelegramPost(thread: 4, user: "u", reply: "r").payload) as? [String: Any]
        XCTAssertNil(without?["conversation"])
    }

    func testShareCommandAddsTheConversationToAnOlderTemplate() {
        let old = TelegramBlock(share: "/bin/wisp topic compartilhar --session={session} --cwd={cwd} --nome={name} --json")
        let command = old.shareCommand(session: "s", cwd: "/tmp", name: "n", conversation: "abc")
        XCTAssertEqual(command?.hasSuffix("--conversation='abc'"), true)
        let custom = TelegramBlock(share: "/bin/other {session}")
        XCTAssertEqual(custom.shareCommand(session: "s", cwd: "/tmp", name: "n", conversation: "abc"), "/bin/other 's'")
    }

    func testContextStartsAfterTheLastReset() {
        let entries = [
            TranscriptEntry(kind: .session, at: "1", engine: "claude", session: "s1", reason: "new"),
            TranscriptEntry(kind: .user, at: "2", surface: "app", text: "antes"),
            TranscriptEntry(kind: .assistant, at: "3", surface: "app", text: "resposta antes", engine: "claude"),
            TranscriptEntry(kind: .session, at: "4", engine: "claude", session: "s2", reason: "reset"),
            TranscriptEntry(kind: .user, at: "5", surface: "telegram", text: "depois"),
        ]
        XCTAssertNil(ConversationTranscript.context(entries))
        let more = entries + [TranscriptEntry(kind: .assistant, at: "6", surface: "telegram", text: "resposta depois", engine: "claude")]
        let context = ConversationTranscript.context(more)
        XCTAssertEqual(context?.contains("depois"), true)
        XCTAssertEqual(context?.contains("antes"), false)
    }

    func testAResetDoesNotHideTheEarlierHistoryFromTheApp() throws {
        let store = TranscriptStore(folder: try folder())
        let key = geral.uuidString.lowercased()
        try store.appendUser(conversation: key, openingSession: "s1", text: "antes", surface: "app")
        try store.appendAssistant(conversation: key, openingSession: nil, text: "resp antes", surface: "app", engine: "claude", model: "")
        try store.link(session: "s2", conversation: key, engine: "claude", reason: "reset")
        try store.appendUser(conversation: key, openingSession: nil, text: "pelo telegram", surface: "telegram")
        try store.appendAssistant(conversation: key, openingSession: nil, text: "resp telegram", surface: "telegram", engine: "claude", model: "")
        XCTAssertEqual(store.sessions(conversation: key), ["s1", "s2"])
        XCTAssertEqual(
            store.earlierMessages(conversation: key, beforeSession: "s2", claude: { _ in nil }).map(\.text), ["antes", "resp antes"])
        XCTAssertTrue(store.earlierMessages(conversation: key, beforeSession: "s1", claude: { _ in nil }).isEmpty)
        let history = TranscriptHistory.load(store: store, sessionId: "s1", conversationKey: key, claude: { _ in nil })
        XCTAssertEqual(history?.map(\.text), ["antes", "resp antes", "pelo telegram", "resp telegram"])
    }

    func testTurnsAnsweredOnTelegramShowInAnAppConversationFoundByItsOwnId() throws {
        let store = TranscriptStore(folder: try folder())
        let key = geral.uuidString.lowercased()
        try store.appendUser(conversation: key, openingSession: "s1", text: "do app", surface: "app")
        try store.appendUser(conversation: key, openingSession: nil, text: "do telegram", surface: "telegram")
        try store.appendAssistant(conversation: key, openingSession: nil, text: "resposta", surface: "telegram", engine: "claude", model: "")
        let found = store.find(session: "s-stale") ?? store.find(session: key)
        XCTAssertEqual(found, key)
        XCTAssertEqual(store.messages(conversation: key).map(\.text), ["do app", "do telegram", "resposta"])
    }

    func testHistoryFromBeforeTheTranscriptExistedIsKeptFromTheClaudeFiles() throws {
        let store = TranscriptStore(folder: try folder())
        let key = geral.uuidString.lowercased()
        try store.link(session: "old", conversation: key, engine: "claude", reason: "merged")
        try store.link(session: "now", conversation: key, engine: "claude", reason: "reset")
        try store.appendUser(conversation: key, openingSession: nil, text: "u2", surface: "app")
        try store.appendAssistant(conversation: key, openingSession: nil, text: "a2", surface: "app", engine: "claude", model: "")
        let files: [String: [ConversationMessage]] = [
            "old": [ConversationMessage(role: .user, text: "u0"), ConversationMessage(role: .assistant, text: "a0")],
            "now": [ConversationMessage(role: .user, text: "u1"), ConversationMessage(role: .assistant, text: "a1"),
                    ConversationMessage(role: .user, text: "u2"), ConversationMessage(role: .assistant, text: "a2")],
        ]
        let history = TranscriptHistory.load(store: store, sessionId: "now", conversationKey: key, claude: { files[$0] })
        XCTAssertEqual(history?.map(\.text), ["u0", "a0", "u1", "a1", "u2", "a2"])
        let earlier = store.earlierMessages(conversation: key, beforeSession: "now", claude: { files[$0] })
        XCTAssertEqual(earlier.map(\.text), ["u0", "a0"])
    }

    func testSectionsPreferTheConversationIdOverANewerRecordWithTheSameSession() {
        let key = geral.uuidString.lowercased()
        let other = UUID()
        let sections = TelegramTopics.sections(
            records: [record(geral, session: "old", at: 0), record(other, session: "live", at: 500)],
            topics: [topic(session: "live", conversation: key)])
        XCTAssertEqual(sections.telegram.first?.record?.id, geral)
        XCTAssertTrue(sections.wisp.isEmpty)
        let two = [topic(session: "live", conversation: nil, thread: 1), topic(session: "live", conversation: nil, thread: 2)]
        var newer = two
        newer[1].lastUsed = day
        XCTAssertEqual(TelegramTopics.topic(forSession: "live", in: newer)?.thread, 2)
    }

    func testTheAssistantAppendReturnsItsStampAndTheMirrorPayloadCarriesIt() throws {
        let store = TranscriptStore(folder: try folder(), stamp: { "2026-11-21T10:00:00.000Z" })
        let key = geral.uuidString.lowercased()
        let at = try store.appendAssistant(conversation: key, openingSession: "s", text: "Feito.", surface: "app", engine: "claude", model: "")
        XCTAssertEqual(at, "2026-11-21T10:00:00.000Z")
        XCTAssertEqual(store.entries(conversation: key).last?.at, at)
        let post = TelegramTopics.mirror(
            sessionId: "s", conversation: geral, topics: [topic(session: "s", conversation: key)], user: "u", reply: "Feito.", turnAt: at)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(post).payload) as? [String: Any]
        XCTAssertEqual(body?["turn_at"] as? String, at)
        let bare = try JSONSerialization.jsonObject(with: TelegramPost(thread: 1, user: "u", reply: "r").payload) as? [String: Any]
        XCTAssertNil(bare?["turn_at"])
    }
}
