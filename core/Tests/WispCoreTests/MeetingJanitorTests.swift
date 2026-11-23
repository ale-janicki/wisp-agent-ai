import XCTest
@testable import WispCore

final class MeetingJanitorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("janitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func entry(
        name: String = "2030-01-01_10-00-00", ageDays: Double = 10, status: RecordingStatus = .noted,
        brainNote: String? = "note", brainError: String? = nil, noteState: NoteState? = nil
    ) -> MeetingEntry {
        var meta = RecordingMeta(
            startedAt: now.addingTimeInterval(-ageDays * day), devices: .init(mic: nil, system: nil), status: status)
        meta.brainNote = brainNote
        meta.brainError = brainError
        meta.noteState = noteState
        return MeetingEntry(folder: dir.appendingPathComponent(name), meta: meta, hasTranscript: true, hasNote: true)
    }

    private func eligible(_ entry: MeetingEntry, exists: Bool = true, excluded: Set<String> = []) -> Bool {
        MeetingJanitor.isEligible(entry, now: now, days: 7, excluded: excluded, brainNoteExists: { _ in exists })
    }

    func testEligible() { XCTAssertTrue(eligible(entry())) }
    func testTooRecent() { XCTAssertFalse(eligible(entry(ageDays: 6))) }
    func testNoBrainNote() { XCTAssertFalse(eligible(entry(brainNote: nil))) }
    func testBrainNoteMissingOnDisk() { XCTAssertFalse(eligible(entry(), exists: false)) }
    func testStatusNotNoted() {
        for status in [RecordingStatus.recording, .transcribing, .transcribed, .failed, .interrupted] {
            XCTAssertFalse(eligible(entry(status: status)), "\(status)")
        }
    }
    func testBrainErrorAndRawNote() {
        XCTAssertFalse(eligible(entry(brainError: "x")))
        XCTAssertFalse(eligible(entry(noteState: .raw)))
    }
    func testExcluded() {
        let item = entry()
        XCTAssertFalse(eligible(item, excluded: [item.id]))
    }
    func testOffWhenZeroDays() {
        XCTAssertFalse(MeetingJanitor.isEligible(entry(), now: now, days: 0, excluded: [], brainNoteExists: { _ in true }))
    }

    func testDateFromFolderNameFallback() {
        let utc = TimeZone(identifier: "UTC")!
        let date = MeetingJanitor.recordingDate(startedAt: nil, folderName: "2030-01-02_03-04-05-2", timeZone: utc)
        XCTAssertEqual(date, Date(timeIntervalSince1970: 1_893_553_445))
        XCTAssertNil(MeetingJanitor.recordingDate(startedAt: nil, folderName: "junk", timeZone: utc))
        XCTAssertEqual(MeetingJanitor.recordingDate(startedAt: now, folderName: "junk"), now)
    }

    func testRewriteLink() throws {
        let home = URL(fileURLWithPath: "/home/someone")
        let folder = home.appendingPathComponent("Wisp/reunioes/2030-01-01_10-00-00")
        let other = home.appendingPathComponent("Wisp/reunioes/2030-01-02_10-00-00")
        let note = "# T\n\n## Transcrição\n\n[Transcrição completa](~/Wisp/reunioes/2030-01-01_10-00-00/nota.md)\n"
        let utc = TimeZone(identifier: "UTC")!
        let result = try XCTUnwrap(MeetingJanitor.rewriteTranscriptLink(in: note, folder: folder, now: now, days: 7, home: home, timeZone: utc))
        XCTAssertEqual(result, "# T\n\n## Transcrição\n\nTranscrição apagada em 15/01/2027 (limpeza automática após 7 dias).\n")
        XCTAssertNil(MeetingJanitor.rewriteTranscriptLink(in: note, folder: other, now: now, days: 7, home: home))
        XCTAssertNil(MeetingJanitor.rewriteTranscriptLink(in: "# T\nno link\n", folder: folder, now: now, days: 7, home: home))
        let absolute = "[Transcrição completa](/home/someone/Wisp/reunioes/2030-01-01_10-00-00/transcript.json)"
        XCTAssertNotNil(MeetingJanitor.rewriteTranscriptLink(in: absolute, folder: folder, now: now, days: 7, home: home))
    }

    func testRunRewritesNoteAndTrashesOnlyEligible() async throws {
        let root = dir.appendingPathComponent("root")
        let brain = dir.appendingPathComponent("brain.md")
        let good = root.appendingPathComponent("2030-01-01_10-00-00")
        let recent = root.appendingPathComponent("2030-01-02_10-00-00")
        for (folder, age, noteURL) in [(good, 10.0, brain), (recent, 1.0, brain)] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var meta = RecordingMeta(
                startedAt: now.addingTimeInterval(-age * day), devices: .init(mic: nil, system: nil), status: .noted)
            meta.brainNote = noteURL.path
            try RecordingFolder.write(meta, in: folder)
        }
        try "x\n[Transcrição completa](\(good.path)/nota.md)\n".write(to: brain, atomically: true, encoding: .utf8)
        var trashed: [URL] = []
        let result = await MeetingJanitor.run(roots: [root], now: now, days: 7, home: dir) { trashed.append($0) }
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(trashed.map(\.lastPathComponent), ["2030-01-01_10-00-00"])
        XCTAssertTrue(try String(contentsOf: brain, encoding: .utf8).contains("Transcrição apagada em"))
    }

    func testTrashFailureNeverHardDeletes() async throws {
        let root = dir.appendingPathComponent("root")
        let folder = root.appendingPathComponent("2030-01-01_10-00-00")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let brain = dir.appendingPathComponent("brain.md")
        try "x".write(to: brain, atomically: true, encoding: .utf8)
        var meta = RecordingMeta(startedAt: now.addingTimeInterval(-10 * day), devices: .init(mic: nil, system: nil), status: .noted)
        meta.brainNote = brain.path
        try RecordingFolder.write(meta, in: folder)
        struct Boom: Error {}
        let result = await MeetingJanitor.run(roots: [root], now: now, days: 7, home: dir) { _ in throw Boom() }
        XCTAssertEqual(result.failed, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }

    func testBrainNoteInsideFolderIsNeverEligible() throws {
        let item = entry()
        let inside = item.folder.appendingPathComponent("brain.md").path
        XCTAssertFalse(MeetingJanitor.isEligible(
            entry(brainNote: inside), now: now, days: 7, excluded: [], brainNoteExists: { _ in true }))
        XCTAssertFalse(MeetingJanitor.isEligible(
            entry(brainNote: item.folder.path), now: now, days: 7, excluded: [], brainNoteExists: { _ in true }))
        let link = dir.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: item.folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: item.folder)
        try "x".write(to: item.folder.appendingPathComponent("brain.md"), atomically: true, encoding: .utf8)
        XCTAssertFalse(MeetingJanitor.isEligible(
            entry(brainNote: link.appendingPathComponent("brain.md").path), now: now, days: 7, excluded: [],
            brainNoteExists: { _ in true }))
    }

    private func seed(_ name: String, note: URL, age: Double = 10) throws -> URL {
        let folder = dir.appendingPathComponent("root").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var meta = RecordingMeta(startedAt: now.addingTimeInterval(-age * day), devices: .init(mic: nil, system: nil), status: .noted)
        meta.brainNote = note.path
        try RecordingFolder.write(meta, in: folder)
        return folder
    }

    func testExclusionMidRunSkipsBeforeWritingNote() async throws {
        let noteA = dir.appendingPathComponent("a.md")
        let noteB = dir.appendingPathComponent("b.md")
        let a = try seed("2030-01-01_10-00-00", note: noteA)
        let b = try seed("2030-01-02_10-00-00", note: noteB, age: 9)
        let text = { (f: URL) in "[Transcrição completa](\(f.path)/nota.md)\n" }
        try text(a).write(to: noteA, atomically: true, encoding: .utf8)
        try text(b).write(to: noteB, atomically: true, encoding: .utf8)
        let blocked = b.lastPathComponent
        var trashed: [String] = []
        let result = await MeetingJanitor.run(
            roots: [dir.appendingPathComponent("root")], now: now, days: 7, home: dir,
            isExcluded: { $0 == blocked }, trash: { trashed.append($0.lastPathComponent) })
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(trashed, [a.lastPathComponent])
        XCTAssertEqual(try String(contentsOf: noteB, encoding: .utf8), text(b))
    }

    func testForeignTranscriptLinkSkipsFolder() async throws {
        let note = dir.appendingPathComponent("n.md")
        let folder = try seed("2030-01-01_10-00-00", note: note)
        try "[Transcrição completa](/elsewhere/other/nota.md)\n".write(to: note, atomically: true, encoding: .utf8)
        var trashed = 0
        let result = await MeetingJanitor.run(roots: [folder.deletingLastPathComponent()], now: now, days: 7, home: dir) { _ in trashed += 1 }
        XCTAssertEqual(result.removed, 0)
        XCTAssertEqual(trashed, 0)
    }

    func testNoTranscriptLinkStillTrashes() async throws {
        let note = dir.appendingPathComponent("n.md")
        let folder = try seed("2030-01-01_10-00-00", note: note)
        try "# only text\n".write(to: note, atomically: true, encoding: .utf8)
        var trashed = 0
        let result = await MeetingJanitor.run(roots: [folder.deletingLastPathComponent()], now: now, days: 7, home: dir) { _ in trashed += 1 }
        XCTAssertEqual(result.removed, 1)
        XCTAssertEqual(trashed, 1)
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "# only text\n")
    }

    func testSymlinkedLinkSpellingStillMatches() throws {
        let real = dir.appendingPathComponent("real/2030-01-01_10-00-00")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let alias = dir.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real.deletingLastPathComponent())
        let note = "[Transcrição completa](\(alias.path)/2030-01-01_10-00-00/nota.md)"
        let scan = MeetingJanitor.scanTranscriptLinks(in: note, folder: real, now: now, days: 7, home: dir)
        XCTAssertNotNil(scan.text)
        XCTAssertEqual(scan.foreign, 0)
    }

    func testSettingDecode() throws {
        XCTAssertEqual(MeetingSettings().cleanupDays, 7)
        let old = try JSONDecoder().decode(MeetingSettings.self, from: Data(#"{"limitMinutes":60}"#.utf8))
        XCTAssertEqual(old.cleanupDays, 7)
        var off = MeetingSettings()
        off.cleanupDays = 0
        let back = try JSONDecoder().decode(MeetingSettings.self, from: JSONEncoder().encode(off))
        XCTAssertEqual(back.cleanupDays, 0)
    }
}
