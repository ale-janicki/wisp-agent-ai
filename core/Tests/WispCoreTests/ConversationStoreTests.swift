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

    func testIndexWithoutClosedFieldsDecodesAsOpen() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let id = UUID()
        let json = """
        [{"id": "\(id.uuidString)", "sessionId": "s", "title": "old", "updatedAt": "2026-01-01T00:00:00.000Z"}]
        """
        try json.write(to: dir.appendingPathComponent("conversations.json"), atomically: true, encoding: .utf8)
        let record = try XCTUnwrap(ConversationStore(directory: dir).all().first)
        XCTAssertNil(record.closedAt)
        XCTAssertNil(record.closedFrom)
        XCTAssertFalse(record.isClosed)
    }

    func testClosedMarkWrittenByTheBotIsReadAndSurvivesReopen() throws {
        let id = UUID()
        let store = ConversationStore(directory: dir)
        try store.upsert(ConversationRecord(id: id, sessionId: "s", title: "t", updatedAt: Date(timeIntervalSince1970: 1_000)))
        let file = dir.appendingPathComponent("conversations.json")
        var text = try String(contentsOf: file, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"id\"", with: "\"closedAt\" : \"2026-02-03T04:05:06Z\", \"closedFrom\" : \"telegram\", \"id\"")
        try text.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: file.path)

        var record = try XCTUnwrap(store.all().first)
        XCTAssertTrue(record.isClosed)
        XCTAssertEqual(record.closedFrom, "telegram")
        XCTAssertEqual(record.closedAt, ISO8601DateFormatter().date(from: "2026-02-03T04:05:06Z"))

        record.closedAt = nil
        record.closedFrom = nil
        try store.upsert(record)
        XCTAssertFalse(try XCTUnwrap(ConversationStore(directory: dir).all().first).isClosed)
    }

    func testClosedMarkRoundTripsThroughThePersistedFile() throws {
        let store = ConversationStore(directory: dir)
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        try store.upsert(ConversationRecord(
            id: UUID(), sessionId: "s", title: "t", updatedAt: when, closedAt: when, closedFrom: "app"))
        let back = try XCTUnwrap(ConversationStore(directory: dir).all().first)
        XCTAssertEqual(back.closedAt, when)
        XCTAssertEqual(back.closedFrom, "app")
    }

    func testMalformedClosedAtReadsAsOpenWithoutLosingTheIndex() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = """
        [{"id": "\(UUID().uuidString)", "title": "t", "updatedAt": "2026-01-01T00:00:00.000Z", "closedAt": "not a date", "closedFrom": "telegram"}]
        """
        try json.write(to: dir.appendingPathComponent("conversations.json"), atomically: true, encoding: .utf8)
        let store = ConversationStore(directory: dir)
        XCTAssertNil(store.lastRecoveryNote)
        let record = try XCTUnwrap(store.all().first)
        XCTAssertFalse(record.isClosed)
        XCTAssertNil(record.closedFrom)
    }

    func testReopenClearsOnlyTheClosedMarkOfTheStoredRecord() throws {
        let id = UUID()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let store = ConversationStore(directory: dir)
        try store.upsert(ConversationRecord(
            id: id, sessionId: "s", title: "fresh", updatedAt: when, lastPreview: "kept", closedAt: when, closedFrom: "telegram"))
        try store.reopen(id: id)
        let back = try XCTUnwrap(ConversationStore(directory: dir).all().first)
        XCTAssertFalse(back.isClosed)
        XCTAssertEqual(back.title, "fresh")
        XCTAssertEqual(back.lastPreview, "kept")
    }

    func testWritesWaitForTheSharedFileLock() throws {
        let store = ConversationStore(directory: dir)
        try store.upsert(ConversationRecord(id: UUID(), sessionId: nil, title: "a", updatedAt: Date()))
        let fd = open(dir.appendingPathComponent("conversations.json.lock").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? store.upsert(ConversationRecord(id: UUID(), sessionId: nil, title: "b", updatedAt: Date()))
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 0.4), .timedOut)
        flock(fd, LOCK_UN)
        close(fd)
        XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(store.all().count, 2)
    }
}
