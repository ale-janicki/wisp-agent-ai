import XCTest
@testable import WispCore

final class ConversationStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wisp-store-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testUpsertThenAllNewestFirst() throws {
        let store = ConversationStore(directory: dir)
        let old = ConversationRecord(id: UUID(), sessionId: nil, title: "old", updatedAt: Date(timeIntervalSince1970: 1_000))
        let new = ConversationRecord(id: UUID(), sessionId: "s1", title: "new", updatedAt: Date(timeIntervalSince1970: 2_000))
        try store.upsert(old)
        try store.upsert(new)
        XCTAssertEqual(store.all().map(\.title), ["new", "old"])

        var edited = old
        edited.title = "old-edited"
        edited.updatedAt = Date(timeIntervalSince1970: 3_000)
        try store.upsert(edited)
        XCTAssertEqual(store.all().map(\.title), ["old-edited", "new"])

        try store.delete(id: new.id)
        XCTAssertEqual(store.all().map(\.title), ["old-edited"])
    }

    func testDeleteSurvivesReloadAndUnknownIdIsNoop() throws {
        let keep = ConversationRecord(id: UUID(), sessionId: "k", title: "keep", updatedAt: Date(timeIntervalSince1970: 1_000))
        let gone = ConversationRecord(id: UUID(), sessionId: "g", title: "gone", updatedAt: Date(timeIntervalSince1970: 2_000))
        let store = ConversationStore(directory: dir)
        try store.upsert(keep)
        try store.upsert(gone)
        try store.delete(id: gone.id)
        try store.delete(id: UUID())
        XCTAssertEqual(store.all().map(\.title), ["keep"])
        XCTAssertEqual(ConversationStore(directory: dir).all().map(\.title), ["keep"])
    }

    func testSurvivesReload() throws {
        let record = ConversationRecord(id: UUID(), sessionId: "abc", title: "hello", updatedAt: Date(timeIntervalSince1970: 1_700_000_000.123456))
        try ConversationStore(directory: dir).upsert(record)
        let reloaded = ConversationStore(directory: dir).all()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertEqual(reloaded.first?.id, record.id)
        XCTAssertEqual(reloaded.first?.sessionId, "abc")
        let delta = abs((reloaded.first?.updatedAt.timeIntervalSince1970 ?? 0) - record.updatedAt.timeIntervalSince1970)
        XCTAssertLessThan(delta, 0.001)
    }

    func testCorruptFileStartsEmptyAndKeepsBackup() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("conversations.json")
        try Data("not json {".utf8).write(to: file)
        let store = ConversationStore(directory: dir)
        XCTAssertTrue(store.all().isEmpty)
        let bad = dir.appendingPathComponent("conversations.json.bad")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bad.path))
        XCTAssertEqual(try Data(contentsOf: bad), Data("not json {".utf8))

        try Data("second".utf8).write(to: file)
        _ = ConversationStore(directory: dir)
        XCTAssertEqual(try Data(contentsOf: bad), Data("second".utf8))
    }

    func testCorruptFileSetsRecoveryNote() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json {".utf8).write(to: dir.appendingPathComponent("conversations.json"))
        let store = ConversationStore(directory: dir)
        let note = try XCTUnwrap(store.lastRecoveryNote)
        XCTAssertTrue(note.contains("conversations.json.bad"), note)
        XCTAssertNil(ConversationStore(directory: dir).lastRecoveryNote)
    }

    func testConcurrentUpsertsAreSafe() throws {
        let store = ConversationStore(directory: dir)
        let failures = NSLock()
        nonisolated(unsafe) var errors = 0
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            let record = ConversationRecord(id: UUID(), sessionId: nil, title: "c\(i)", updatedAt: Date(timeIntervalSince1970: Double(i)))
            do { try store.upsert(record) } catch { failures.lock(); errors += 1; failures.unlock() }
        }
        XCTAssertEqual(errors, 0)
        XCTAssertEqual(store.all().count, 200)
        XCTAssertEqual(ConversationStore(directory: dir).all().count, 200)
    }
}
