import XCTest
@testable import WispCore

private struct IdleRecognizer: SpeechRecognizer {
    let engineName = "fake-asr"
    func transcribe(_ samples: [Float], language: String?) async throws -> [RecognizedSpan] { [] }
}

private final class BrainSpy: MeetingBrainWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [(folder: String, hadNote: Bool)] = []
    var failure: String?
    var saved: URL

    init(saved: URL) { self.saved = saved }

    var calls: [(folder: String, hadNote: Bool)] { lock.withLock { log } }

    func syncNote(folder: URL) async throws -> URL {
        let hadNote = FileManager.default.fileExists(atPath: RecordingFolder.noteURL(in: folder).path)
        lock.withLock { log.append((folder.lastPathComponent, hadNote)) }
        if let failure { throw NoteWriterError.failed(failure) }
        return saved
    }
}

private struct NoteWriterError: Error, LocalizedError {
    var reason: String
    var errorDescription: String? { reason }
    static func failed(_ reason: String) -> NoteWriterError { NoteWriterError(reason: reason) }
}

private struct SummaryWriter: MeetingNoteWriter {
    func writeNote(folder: URL) async throws -> NoteOutcome {
        try Data("# Roadmap\n\n## Resumo\n\nOk.\n".utf8).write(to: RecordingFolder.noteURL(in: folder))
        return NoteOutcome(generated: true, title: "Roadmap")
    }
}

final class MeetingBrainSyncTests: XCTestCase {
    private var root: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-brain-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func event(_ id: String, _ start: Double, _ end: Double, title: String = "E", people: Int = 1, allDay: Bool = false, declined: Bool = false) -> CalEvent {
        CalEvent(
            id: id, calendarID: "c1", title: title, start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end), allDay: allDay,
            attendees: (0..<people).map { CalAttendee(name: "P\($0)", email: "p\($0)@example.com") }, declined: declined
        )
    }

    private func recorded(deferred: Bool?) throws -> URL {
        let folder = root.appendingPathComponent("rec", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var meta = RecordingMeta(startedAt: t0, durationSeconds: 60, devices: .init(mic: "m", system: "s"), status: .transcribed)
        meta.summaryDeferred = deferred
        try RecordingFolder.write(meta, in: folder)
        let document = MeetingTranscriptDocument(
            startedAt: t0, durationSeconds: 60, engine: "fake-asr",
            segments: [MeetingSegment(start: 0, end: 2, speaker: "eu", text: "oi")]
        )
        try MeetingTranscriptFile.write(document, in: folder)
        return folder
    }

    private func pipeline(_ spy: BrainSpy) -> MeetingPipeline {
        MeetingPipeline(transcriber: MeetingTranscriber(recognizer: IdleRecognizer()), notes: SummaryWriter(), brain: spy)
    }

    func testPicksTheEventWithTheLargestOverlap() {
        let long = event("long", -600, 3600, title: "Longo")
        let short = event("short", 0, 600, title: "Curto")
        let picked = MeetingEventMatcher.pick(events: [short, long], from: t0, to: t0.addingTimeInterval(1800))
        XCTAssertEqual(picked?.id, "long")
    }

    func testIgnoresAllDayDeclinedAndNonOverlappingEvents() {
        let events = [
            event("day", -3600, 3600, allDay: true), event("no", -3600, 3600, declined: true),
            event("before", -3600, -10), event("after", 400, 900),
        ]
        XCTAssertNil(MeetingEventMatcher.pick(events: events, from: t0, to: t0.addingTimeInterval(300)))
    }

    func testStartedEventWinsAtRecordingStartAndTiesPreferAttendeesThenShorter() {
        let started = event("started", -900, 1800, title: "Em andamento")
        XCTAssertEqual(MeetingEventMatcher.pick(events: [started], from: t0, to: t0)?.id, "started")
        let solo = event("solo", 0, 600, people: 0)
        let team = event("team", 0, 600, people: 2)
        XCTAssertEqual(MeetingEventMatcher.pick(events: [solo, team], from: t0, to: t0.addingTimeInterval(600))?.id, "team")
        let wide = event("wide", 0, 3600)
        let narrow = event("narrow", 0, 900)
        XCTAssertEqual(MeetingEventMatcher.pick(events: [wide, narrow], from: t0, to: t0.addingTimeInterval(600))?.id, "narrow")
    }

    func testEventInfoDropsMeKeepsOrganizerAndMeetingLink() {
        let calEvent = CalEvent(
            id: "1", calendarID: "c", title: "Plano", start: t0, end: t0.addingTimeInterval(1800), notes: "  Pauta \nhttps://meet.google.com/abc-defg-hij  ",
            attendees: [
                CalAttendee(name: "Ana", email: "ana@example.com", isOrganizer: true),
                CalAttendee(name: "Eu", email: "eu@example.com", isMe: true),
                CalAttendee(name: "Bruno", email: "bruno@example.com"),
            ]
        )
        let info = MeetingEventInfo(event: calEvent, calendarTitle: "Trabalho")
        XCTAssertEqual(info.title, "Plano")
        XCTAssertEqual(info.calendar, "Trabalho")
        XCTAssertEqual(info.organizer, MeetingPerson(name: "Ana", email: "ana@example.com"))
        XCTAssertEqual(info.attendees.map(\.name), ["Ana", "Bruno"])
        XCTAssertEqual(info.url, "https://meet.google.com/abc-defg-hij")
        let data = try? JSONEncoder().encode(info)
        XCTAssertEqual(data.flatMap { try? JSONDecoder().decode(MeetingEventInfo.self, from: $0) }, info)
    }

    func testMetaKeepsTheEventAndOldMetaStillDecodes() throws {
        let folder = try recorded(deferred: nil)
        _ = try RecordingFolder.update(in: folder) {
            $0.event = MeetingEventInfo(title: "Plano", attendees: [MeetingPerson(name: "Ana")])
            $0.summaryDeferred = true
        }
        let json = try String(contentsOf: RecordingFolder.metaURL(in: folder), encoding: .utf8)
        XCTAssertTrue(json.contains("\"summary_deferred\""))
        let meta = try RecordingFolder.read(in: folder)
        XCTAssertEqual(meta.event?.attendees.first?.name, "Ana")
        XCTAssertEqual(meta.summaryDeferred, true)
        XCTAssertNil(try RecordingFolder.read(in: recorded(deferred: nil)).event)
    }

    func testSettingDefaultsToOnAndSurvivesOldSettings() throws {
        XCTAssertTrue(MeetingSettings().autoSummary)
        let old = try JSONDecoder().decode(MeetingSettings.self, from: Data(#"{"limitMinutes":60}"#.utf8))
        XCTAssertTrue(old.autoSummary)
        var off = MeetingSettings()
        off.autoSummary = false
        let back = try JSONDecoder().decode(MeetingSettings.self, from: JSONEncoder().encode(off))
        XCTAssertFalse(back.autoSummary)
    }

    func testAutoFlowWritesTheSummaryThenTheBrainNote() async throws {
        let folder = try recorded(deferred: nil)
        let saved = root.appendingPathComponent("brain/meetings/x.md")
        let spy = BrainSpy(saved: saved)
        XCTAssertTrue(MeetingLibrary.list(root: root).allSatisfy { MeetingLibrary.needsProcessing($0) })
        try await pipeline(spy).process(folder: folder)
        XCTAssertEqual(spy.calls.map(\.hadNote), [true])
        let meta = try RecordingFolder.read(in: folder)
        XCTAssertEqual(meta.status, .noted)
        XCTAssertEqual(meta.noteState, .generated)
        XCTAssertEqual(meta.brainNote, saved.path)
        XCTAssertNil(meta.brainError)
    }

    func testManualFlowWritesTheBrainNoteWithoutSummaryAndFillsItLater() async throws {
        let folder = try recorded(deferred: true)
        let spy = BrainSpy(saved: root.appendingPathComponent("brain/meetings/x.md"))
        XCTAssertFalse(MeetingLibrary.list(root: root).contains { MeetingLibrary.needsProcessing($0) })
        try await pipeline(spy).process(folder: folder)
        XCTAssertEqual(spy.calls.map(\.hadNote), [false])
        var meta = try RecordingFolder.read(in: folder)
        XCTAssertEqual(meta.status, .transcribed)
        XCTAssertNil(meta.noteFile)
        XCTAssertEqual(meta.brainNote, spy.saved.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingFolder.noteURL(in: folder).path))

        try await pipeline(spy).regenerateNote(folder: folder)
        XCTAssertEqual(spy.calls.map(\.hadNote), [false, true])
        meta = try RecordingFolder.read(in: folder)
        XCTAssertEqual(meta.status, .noted)
        XCTAssertEqual(meta.noteState, .generated)
    }

    func testBrainFailureIsRecordedAndDoesNotFailTheMeeting() async throws {
        let folder = try recorded(deferred: nil)
        let spy = BrainSpy(saved: root.appendingPathComponent("x.md"))
        spy.failure = "o brain não existe"
        try await pipeline(spy).process(folder: folder)
        let meta = try RecordingFolder.read(in: folder)
        XCTAssertEqual(meta.status, .noted)
        XCTAssertEqual(meta.brainError, "o brain não existe")
        XCTAssertNil(meta.brainNote)
    }

    func testBrainButtonOpensTheSyncedNoteOrSyncsAgain() throws {
        let note = root.appendingPathComponent("n.md")
        try Data("x".utf8).write(to: note)
        let exists = { (path: String) in FileManager.default.fileExists(atPath: path) }
        XCTAssertEqual(MeetingBrainButton.make(brainNote: note.path, exists: exists(note.path)), MeetingBrainButton(label: "Abrir no brain", opensNote: true))
        XCTAssertEqual(MeetingBrainButton.make(brainNote: nil, exists: false), MeetingBrainButton(label: "Salvar no brain", opensNote: false))
        let gone = root.appendingPathComponent("gone.md").path
        XCTAssertFalse(MeetingBrainButton.make(brainNote: gone, exists: exists(gone)).opensNote)
    }
}
