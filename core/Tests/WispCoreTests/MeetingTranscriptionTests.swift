import AVFoundation
import CryptoKit
import XCTest
@testable import WispCore

private final class ScriptedRecognizer: SpeechRecognizer, @unchecked Sendable {
    let engineName = "fake-asr"
    private let lock = NSLock()
    private var calls = 0
    private(set) var seen: [Int] = []
    var failAfter: Int?

    func transcribe(_ samples: [Float], language: String?) async throws -> [RecognizedSpan] {
        let number = lock.withLock { () -> Int in
            calls += 1
            seen.append(samples.count)
            return calls
        }
        if let failAfter, number > failAfter { throw MeetingTranscriberError.audio("modelo quebrou") }
        return [RecognizedSpan(text: "fala\(number)", start: 0, end: Double(samples.count) / 16_000, confidence: 0.9)]
    }
}

private struct FixedNoteWriter: MeetingNoteWriter {
    var outcome = NoteOutcome(generated: true, title: "Alinhamento do roadmap")
    var failure: String?

    func writeNote(folder: URL) async throws -> NoteOutcome {
        if let failure { throw MeetingTranscriberError.audio(failure) }
        try Data("# Alinhamento do roadmap\n\n## Resumo\n\nOk.\n".utf8).write(to: RecordingFolder.noteURL(in: folder))
        return outcome
    }
}

private final class MemoryFetcher: ModelFileFetcher, @unchecked Sendable {
    var contents: [String: Data]
    var corrupt: Set<String> = []
    private(set) var fetched: [String] = []

    init(contents: [String: Data]) { self.contents = contents }

    func fetch(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let name = url.lastPathComponent
        fetched.append(name)
        var data = contents[name] ?? Data()
        if corrupt.contains(name) { data = Data(repeating: 0x41, count: data.count) }
        try data.write(to: destination)
        progress(Int64(data.count) / 2)
        progress(Int64(data.count))
    }
}

private struct FixedDisk: DiskSpace {
    var bytes: Int64?
    func availableBytes(at url: URL) -> Int64? { bytes }
}

final class MeetingTranscriptionTests: XCTestCase {
    private var root: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-tx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func tone(seconds: Double, amplitude: Float = 0.3, rate: Int = 16_000) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { amplitude * sin(Float($0) * 0.05) }
    }

    private func span(_ text: String, _ start: Double, _ end: Double) -> RecognizedSpan {
        RecognizedSpan(text: text, start: start, end: end)
    }

    // MARK: channels and labels

    func testChannelsMapToSpeakerNamesTheUserSees() {
        XCTAssertEqual(AudioChannel.mic.speaker, "eu")
        XCTAssertEqual(AudioChannel.system.speaker, "outros")
        XCTAssertEqual(AudioChannel.mic.displayName, "Você")
        XCTAssertEqual(AudioChannel.system.displayName, "Outros")
        XCTAssertEqual(AudioChannel(speaker: "outros"), .system)
        XCTAssertNil(AudioChannel(speaker: "falante-1"))
        let line = TranscriptLine(MeetingSegment(start: 65, end: 70, speaker: "falante-2", text: "oi"))
        XCTAssertEqual(line.speaker, "falante-2")
        XCTAssertEqual(line.time, "1:05")
    }

    // MARK: segmenting

    func testStreamerCutsFiveSecondWindowsWithOneSecondOverlapAndPartialsBetween() {
        var streamer = ChannelStreamer(channel: .mic)
        var jobs: [StreamJob] = []
        for _ in 0..<12 { jobs += streamer.append(tone(seconds: 1)) }
        let finals = jobs.filter { $0.kind == .final }
        XCTAssertEqual(finals.map(\.startSeconds), [0, 4])
        XCTAssertEqual(finals.map { $0.samples.count }, [80_000, 80_000])
        let partials = jobs.filter { $0.kind == .partial }
        XCTAssertFalse(partials.isEmpty)
        XCTAssertTrue(partials.allSatisfy { $0.samples.count <= 80_000 && $0.channel == .mic })
        let flushed = streamer.flush()
        XCTAssertEqual(flushed.map(\.startSeconds), [8])
        XCTAssertEqual(flushed.first?.samples.count, 64_000)
    }

    func testStreamerEmitsAtMostOnePartialPerIntervalAndNoneWithoutEnoughAudio() {
        var streamer = ChannelStreamer(channel: .system)
        XCTAssertEqual(streamer.append(tone(seconds: 1.0)), [])
        let jobs = streamer.append(tone(seconds: 1.0))
        XCTAssertEqual(jobs.map(\.kind), [.partial])
        XCTAssertEqual(jobs.first?.samples.count, 32_000)
        XCTAssertEqual(streamer.append(tone(seconds: 0.5)), [])
    }

    func testSilentWindowIsNotSentToTheRecognizerButStillClosesTheWindow() {
        var streamer = ChannelStreamer(channel: .mic)
        let jobs = streamer.append([Float](repeating: 0, count: 80_000))
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.kind, .final)
        XCTAssertEqual(jobs.first?.samples, [])
    }

    func testFlushSkipsTailAlreadyCoveredByTheLastWindowAndTinyTails() {
        var covered = ChannelStreamer(channel: .mic)
        _ = covered.append(tone(seconds: 5))
        XCTAssertEqual(covered.flush(), [])
        var tiny = ChannelStreamer(channel: .mic)
        _ = tiny.append(tone(seconds: 0.3))
        XCTAssertEqual(tiny.flush(), [])
    }

    func testDecimatorGivesOneThirdAndKeepsTheRemainderAcrossCalls() {
        var decimator = Decimator48To16()
        XCTAssertEqual(decimator.process([3, 3, 3, 6, 6]), [3])
        XCTAssertEqual(decimator.process([6]), [6])
        XCTAssertEqual(decimator.process([]), [])
    }

    func testLevelNormalizationMapsDecibelsToUnitRange() {
        XCTAssertEqual(SignalLevel.normalized(rms: 0), 0)
        XCTAssertEqual(SignalLevel.normalized(rms: 1), 1, accuracy: 0.001)
        XCTAssertEqual(SignalLevel.normalized(rms: 0.001), 0, accuracy: 0.001)
        XCTAssertEqual(SignalLevel.normalized(rms: 0.0316), 0.5, accuracy: 0.01)
    }

    // MARK: partial to final merge

    func testPartialIsReplacedByTheNextPartialAndDisappearsOnFinal() {
        var merger = TranscriptMerger()
        merger.setPartial(span("ola", 0, 1), channel: .mic)
        merger.setPartial(span("ola pessoal", 0, 2), channel: .mic)
        XCTAssertEqual(merger.snapshot.map(\.text), ["ola pessoal"])
        XCTAssertEqual(merger.snapshot.first?.isFinal, false)
        merger.commit([span("Olá, pessoal.", 0, 2.4)], channel: .mic)
        XCTAssertEqual(merger.snapshot.map(\.text), ["Olá, pessoal."])
        XCTAssertEqual(merger.snapshot.first?.isFinal, true)
    }

    func testOverlapRepeatedWordsAreDroppedFromTheNextFinal() {
        var merger = TranscriptMerger()
        merger.commit([span("vamos começar pelo roadmap do trimestre", 0, 5)], channel: .system)
        merger.commit([span("roadmap do trimestre e depois o orçamento", 4, 9)], channel: .system)
        XCTAssertEqual(merger.finals.map(\.text), ["vamos começar pelo roadmap do trimestre", "e depois o orçamento"])
    }

    func testPunctuationAndCaseDoNotHideTheOverlap() {
        XCTAssertEqual(TranscriptMerger.dropRepeatedPrefix(of: "Do trimestre, e depois", after: "o roadmap do trimestre"), "e depois")
        XCTAssertEqual(TranscriptMerger.dropRepeatedPrefix(of: "algo novo", after: "algo velho"), "algo novo")
    }

    func testFullyRepeatedFinalIsDroppedAndFarAwayRepeatIsKept() {
        var merger = TranscriptMerger()
        merger.commit([span("tudo certo", 0, 2)], channel: .mic)
        merger.commit([span("tudo certo", 1, 3)], channel: .mic)
        XCTAssertEqual(merger.finals.count, 1)
        merger.commit([span("tudo certo", 30, 32)], channel: .mic)
        XCTAssertEqual(merger.finals.count, 2)
    }

    func testChannelsMergeIndependentlyAndSortByTime() {
        var merger = TranscriptMerger()
        merger.commit([span("segunda fala", 10, 12)], channel: .mic)
        merger.commit([span("primeira fala", 2, 4)], channel: .system)
        merger.commit([span("segunda fala", 10.5, 12)], channel: .system)
        XCTAssertEqual(merger.snapshot.map(\.speaker), ["outros", "eu", "outros"])
        XCTAssertEqual(merger.snapshot.map(\.text), ["primeira fala", "segunda fala", "segunda fala"])
        XCTAssertEqual(merger.snapshot.map(\.speakerName), ["Outros", "Você", "Outros"])
    }

    func testEmptyTextClearsThePartial() {
        var merger = TranscriptMerger()
        merger.setPartial(span("algo", 0, 1), channel: .mic)
        merger.setPartial(span("  ", 0, 1), channel: .mic)
        XCTAssertEqual(merger.snapshot, [])
    }

    func testTidyJoinsAdjacentSameSpeakerLinesButNotAcrossSpeakers() {
        let segments = [
            MeetingSegment(start: 0, end: 2, speaker: "eu", text: "um"),
            MeetingSegment(start: 2.5, end: 4, speaker: "eu", text: "dois"),
            MeetingSegment(start: 4.2, end: 5, speaker: "outros", text: "três"),
            MeetingSegment(start: 5.5, end: 6, speaker: "eu", text: "quatro"),
            MeetingSegment(start: 20, end: 21, speaker: "eu", text: "cinco"),
        ]
        let tidy = TranscriptTidy.mergeAdjacent(segments)
        XCTAssertEqual(tidy.map(\.text), ["um dois", "três", "quatro", "cinco"])
        XCTAssertEqual(tidy.first?.end, 4)
    }

    // MARK: transcript store

    func testStoreSavesLiveTranscriptOnEveryCommitAndRoundTrips() throws {
        let store = MeetingTranscriptStore(startedAt: t0, engine: "fake-asr", folder: root)
        store.setPartial(span("ainda falando", 6, 7), channel: .mic)
        XCTAssertFalse(FileManager.default.fileExists(atPath: MeetingTranscriptFile.url(in: root, live: true).path))
        XCTAssertEqual(store.snapshot.map(\.isFinal), [false])
        store.commit([span("bom dia", 0, 1.5)], channel: .mic)
        store.commit([span("bom dia, tudo bem?", 2, 4)], channel: .system)
        let live = try MeetingTranscriptFile.read(in: root, live: true)
        XCTAssertEqual(live.segments.map(\.speaker), ["eu", "outros"])
        XCTAssertEqual(live.engine, "fake-asr")
        XCTAssertEqual(live.startedAt, t0)
        XCTAssertEqual(store.snapshot.count, 2)
        XCTAssertEqual(store.finals.count, 2)
        let attributes = try FileManager.default.attributesOfItem(atPath: MeetingTranscriptFile.url(in: root, live: true).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testTranscriptJSONUsesSpecKeysAndPlainTextHasTimeAndSpeaker() throws {
        let document = MeetingTranscriptDocument(
            startedAt: t0, durationSeconds: 90, language: "auto", engine: "fake-asr",
            segments: [MeetingSegment(start: 61, end: 64, speaker: "eu", text: "fechado", confidence: 0.8)]
        )
        try MeetingTranscriptFile.write(document, in: root)
        let raw = try String(contentsOf: MeetingTranscriptFile.url(in: root), encoding: .utf8)
        for key in ["\"started_at\"", "\"duration_s\"", "\"segments\"", "\"speaker\"", "\"confidence\"", "\"engine\"", "\"language\""] {
            XCTAssertTrue(raw.contains(key), key)
        }
        XCTAssertFalse(raw.contains("isFinal"))
        XCTAssertEqual(try MeetingTranscriptFile.read(in: root), document)
        XCTAssertEqual(document.plainText(), "[1:01] Você: fechado")
    }

    // MARK: live transcriber

    func testLiveTranscriberLabelsChannelsAndPublishesPartialThenFinal() async throws {
        let recognizer = ScriptedRecognizer()
        let store = MeetingTranscriptStore(startedAt: t0, engine: recognizer.engineName)
        let updates = UpdateLog()
        let live = LiveTranscriber(recognizer: recognizer, store: store, onUpdate: { updates.add($0) })
        for _ in 0..<7 {
            live.push16k(tone(seconds: 1), channel: .mic)
            live.push16k(tone(seconds: 1), channel: .system)
        }
        let result = await live.finish()
        XCTAssertTrue(result.allSatisfy { $0.isFinal })
        XCTAssertEqual(Set(result.map(\.speakerName)), ["Você", "Outros"])
        XCTAssertEqual(result.filter { $0.speaker == "eu" }.count, 2)
        XCTAssertEqual(result.filter { $0.speaker == "outros" }.count, 2)
        XCTAssertTrue(updates.all.contains { $0.contains { !$0.isFinal } } || recognizer.seen.count >= 4)
        XCTAssertEqual(result.map(\.start), result.map(\.start).sorted())
    }

    func testLiveTranscriberKeepsGoingWhenTheRecognizerFailsAndReportsOnce() async {
        let recognizer = ScriptedRecognizer()
        recognizer.failAfter = 0
        let failures = UpdateLog()
        let live = LiveTranscriber(
            recognizer: recognizer, store: MeetingTranscriptStore(startedAt: t0, engine: "x"), onUpdate: { _ in },
            onFailure: { failures.note($0) }
        )
        for _ in 0..<12 { live.push16k(tone(seconds: 1), channel: .mic) }
        let result = await live.finish()
        XCTAssertEqual(result, [])
        XCTAssertEqual(failures.notes.count, 1)
    }

    func testLiveTranscriberDecimates48kInputToTheRecognizerRate() async {
        let recognizer = ScriptedRecognizer()
        let live = LiveTranscriber(recognizer: recognizer, store: MeetingTranscriptStore(startedAt: t0, engine: "x"), onUpdate: { _ in })
        for _ in 0..<6 { live.push48k(tone(seconds: 1, rate: 48_000), channel: .mic) }
        _ = await live.finish()
        XCTAssertTrue(recognizer.seen.contains(80_000))
    }

    // MARK: pipeline end to end

    private func writeWAV(to url: URL, seconds: Double, micRange: ClosedRange<Double>, systemRange: ClosedRange<Double>) throws {
        let rate = 48_000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for index in 0..<Int(frames) {
            let time = Double(index) / rate
            let wave = 0.3 * sin(Float(index) * 0.1)
            data[0][index] = micRange.contains(time) ? wave : 0
            data[1][index] = systemRange.contains(time) ? wave : 0
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    private func makeRecording(status: RecordingStatus, sources: RecordingSources = .both) throws -> URL {
        let folder = try RecordingFolder.create(root: root, date: t0, timeZone: TimeZone(identifier: "UTC")!)
        let wav = root.appendingPathComponent("fixture-\(UUID().uuidString).wav")
        try writeWAV(to: wav, seconds: 9, micRange: 0...6, systemRange: 3...9)
        _ = try M4AFileConverter().convert(from: wav, to: RecordingFolder.audioURL(in: folder))
        try? FileManager.default.removeItem(at: wav)
        let meta = RecordingMeta(
            startedAt: t0, durationSeconds: 9, devices: .init(mic: "mic", system: "sys"), status: status, sources: sources
        )
        try RecordingFolder.write(meta, in: folder)
        return folder
    }

    private func pipeline(_ recognizer: ScriptedRecognizer = ScriptedRecognizer(), notes: MeetingNoteWriter = FixedNoteWriter()) -> MeetingPipeline {
        MeetingPipeline(
            transcriber: MeetingTranscriber(
                recognizer: recognizer, config: ChannelStreamerConfig(windowSeconds: 4, overlapSeconds: 1, emitsPartials: false)
            ),
            notes: notes
        )
    }

    func testPipelineTranscribesBothChannelsFromAWavFixtureAndWritesTheNote() async throws {
        let folder = try makeRecording(status: .transcribing)
        let stages = UpdateLog()
        try await pipeline().process(folder: folder, stage: { stages.stage($0) })
        let document = try MeetingTranscriptFile.read(in: folder)
        XCTAssertEqual(document.engine, "fake-asr")
        XCTAssertEqual(Set(document.segments.map(\.speaker)), ["eu", "outros"])
        let mine = document.segments.filter { $0.speaker == "eu" }
        let theirs = document.segments.filter { $0.speaker == "outros" }
        XCTAssertEqual(mine.first?.start ?? -1, 0, accuracy: 0.3)
        XCTAssertGreaterThan(theirs.map(\.end).max() ?? 0, 8)
        XCTAssertLessThanOrEqual(mine.map(\.end).max() ?? 99, 7.2)
        XCTAssertEqual(document.segments.map(\.start), document.segments.map(\.start).sorted())
        let meta = try RecordingFolder.read(in: folder)
        XCTAssertEqual(meta.status, .noted)
        XCTAssertEqual(meta.noteFile, "nota.md")
        XCTAssertEqual(meta.noteState, .generated)
        XCTAssertEqual(meta.title, "Alinhamento do roadmap")
        XCTAssertNil(meta.failure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingFolder.noteURL(in: folder).path))
        XCTAssertTrue(stages.stages.contains(.writingNote))
        XCTAssertTrue(stages.stages.contains { if case .transcribing(let f) = $0 { return f > 0.9 } else { return false } })
    }

    func testPipelineSkipsTheSilentChannelWhenOnlyTheMicWasRecorded() async throws {
        let folder = try makeRecording(status: .transcribing, sources: .mic)
        try await pipeline().process(folder: folder)
        let document = try MeetingTranscriptFile.read(in: folder)
        XCTAssertEqual(Set(document.segments.map(\.speaker)), ["eu"])
    }

    func testNoteFailureStillLeavesARawNoteWithTheTranscriptAndTheReason() async throws {
        let folder = try makeRecording(status: .transcribing)
        try await pipeline(notes: FixedNoteWriter(failure: "motor sem login")).process(folder: folder)
        let meta = try RecordingFolder.read(in: folder)
        XCTAssertEqual(meta.status, .noted)
        XCTAssertEqual(meta.noteState, .raw)
        XCTAssertEqual(meta.failure, "nota não gerada: Não consegui ler o áudio: motor sem login")
        let note = try String(contentsOf: RecordingFolder.noteURL(in: folder), encoding: .utf8)
        XCTAssertTrue(note.contains("Nota não gerada"))
        XCTAssertTrue(note.contains("Você:"))
        XCTAssertTrue(note.contains("Outros:"))
    }

    func testRecognizerFailureMarksTheMeetingFailedAndRetryingWorks() async throws {
        let folder = try makeRecording(status: .transcribing)
        let broken = ScriptedRecognizer()
        broken.failAfter = 0
        do {
            try await pipeline(broken).process(folder: folder)
            XCTFail("should throw")
        } catch {}
        var meta = try RecordingFolder.read(in: folder)
        XCTAssertEqual(meta.status, .failed)
        XCTAssertTrue(meta.failure?.hasPrefix("não consegui transcrever") == true)
        meta.status = .transcribing
        try RecordingFolder.write(meta, in: folder)
        try await pipeline().process(folder: folder)
        XCTAssertEqual(try RecordingFolder.read(in: folder).status, .noted)
    }

    func testNoSpeechLeavesTheMeetingTranscribedWithAReasonAndNoNote() async throws {
        let folder = try RecordingFolder.create(root: root, date: t0, timeZone: TimeZone(identifier: "UTC")!)
        let wav = root.appendingPathComponent("silent.wav")
        try writeWAV(to: wav, seconds: 3, micRange: 100...101, systemRange: 100...101)
        _ = try M4AFileConverter().convert(from: wav, to: RecordingFolder.audioURL(in: folder))
        try RecordingFolder.write(RecordingMeta(startedAt: t0, durationSeconds: 3, devices: .init(mic: nil, system: nil), status: .transcribing), in: folder)
        try await pipeline().process(folder: folder)
        let meta = try RecordingFolder.read(in: folder)
        XCTAssertEqual(meta.status, .transcribed)
        XCTAssertEqual(meta.failure, "nenhuma fala detectada nessa gravação")
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingFolder.noteURL(in: folder).path))
    }

    func testRegenerateNoteReplacesARawNote() async throws {
        let folder = try makeRecording(status: .transcribing)
        try await pipeline(notes: FixedNoteWriter(failure: "sem rede")).process(folder: folder)
        try? FileManager.default.removeItem(at: RecordingFolder.noteURL(in: folder))
        try await pipeline().regenerateNote(folder: folder)
        let meta = try RecordingFolder.read(in: folder)
        XCTAssertEqual(meta.noteState, .generated)
        XCTAssertNil(meta.failure)
    }

    // MARK: recovery

    func testARecoveredRecordingIsPickedUpAndTranscribed() async throws {
        let folder = try RecordingFolder.create(root: root, date: t0, timeZone: TimeZone(identifier: "UTC")!)
        let sink = try StereoFileSink(url: RecordingFolder.rawAudioURL(in: folder), container: .pcm16)
        var frames: [Float] = []
        for index in 0..<(48_000 * 6) {
            let wave = 0.3 * sin(Float(index) * 0.1)
            frames += [wave, index > 48_000 * 2 ? wave : 0]
        }
        try sink.write(frames)
        try sink.finish()
        try RecordingFolder.write(RecordingMeta(startedAt: t0, devices: .init(mic: "mic", system: "sys")), in: folder)

        let recovered = RecordingRecovery.recover(root: root, converter: M4AFileConverter())
        XCTAssertEqual(recovered.count, 1)
        let pending = MeetingLibrary.pending(root: root)
        XCTAssertEqual(pending.map(\.id), [folder.lastPathComponent])
        XCTAssertEqual(pending.first?.meta.status, .interrupted)

        try await pipeline().process(folder: folder)
        XCTAssertEqual(try RecordingFolder.read(in: folder).status, .noted)
        XCTAssertEqual(MeetingLibrary.pending(root: root), [])
        XCTAssertEqual(Set(try MeetingTranscriptFile.read(in: folder).segments.map(\.speaker)), ["eu", "outros"])
    }

    func testLibraryListsNewestFirstAndSkipsFoldersWithoutMeta() throws {
        let older = try RecordingFolder.create(root: root, date: t0, timeZone: TimeZone(identifier: "UTC")!)
        let newer = try RecordingFolder.create(root: root, date: t0.addingTimeInterval(3600), timeZone: TimeZone(identifier: "UTC")!)
        try RecordingFolder.write(RecordingMeta(startedAt: t0, devices: .init(mic: nil, system: nil), status: .noted), in: older)
        try RecordingFolder.write(RecordingMeta(startedAt: t0.addingTimeInterval(3600), devices: .init(mic: nil, system: nil), status: .recording), in: newer)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("modelos"), withIntermediateDirectories: true)
        let listed = MeetingLibrary.list(root: root)
        XCTAssertEqual(listed.map(\.id), [newer.lastPathComponent, older.lastPathComponent])
        XCTAssertEqual(MeetingLibrary.pending(root: root, excluding: []), [])
    }

    // MARK: model download

    private func smallSpec() -> (SpeechModelSpec, MemoryFetcher) {
        let a = Data("alpha-weights".utf8), b = Data("{\"vocab\":1}".utf8)
        func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        func gitSha(_ data: Data) -> String {
            var hasher = Insecure.SHA1()
            hasher.update(data: Data("blob \(data.count)\0".utf8))
            hasher.update(data: data)
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let spec = SpeechModelSpec(
            name: "Fake", repo: "owner/fake", revision: "abc123", folderName: "fake-model", license: "MIT",
            files: [
                SpeechModelFile(path: "Enc.mlmodelc/weights/weight.bin", size: Int64(a.count), hash: .sha256(sha(a))),
                SpeechModelFile(path: "vocab.json", size: Int64(b.count), hash: .gitBlobSHA1(gitSha(b))),
            ]
        )
        return (spec, MemoryFetcher(contents: ["weight.bin": a, "vocab.json": b]))
    }

    private func gitOnlyPinnedSpec() -> (SpeechModelSpec, MemoryFetcher) {
        let b = Data("{\"vocab\":1}".utf8)
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(b.count)\0".utf8))
        hasher.update(data: b)
        let git = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let sha = SHA256.hash(data: b).map { String(format: "%02x", $0) }.joined()
        let spec = SpeechModelSpec(
            name: "Fake", repo: "owner/fake", revision: "abc123", folderName: "fake-model", license: "MIT",
            files: [SpeechModelFile(path: "vocab.json", size: Int64(b.count), hash: .gitBlobSHA1(git), sha256: sha)]
        )
        return (spec, MemoryFetcher(contents: ["vocab.json": b]))
    }

    func testDownloadVerifiesHashesReportsProgressAndMarksTheModelInstalled() async throws {
        let (spec, fetcher) = smallSpec()
        let progress = UpdateLog()
        let downloader = SpeechModelDownloader(fetcher: fetcher, diskSpace: FixedDisk(bytes: 100_000_000_000))
        XCTAssertFalse(SpeechModelLocation.isInstalled(spec, at: SpeechModelLocation.directory(for: spec, wispDir: root)))
        try await downloader.download(spec, wispDir: root, progress: { progress.bytes($0, $1) })
        let target = SpeechModelLocation.directory(for: spec, wispDir: root)
        XCTAssertTrue(SpeechModelLocation.isInstalled(spec, at: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.deletingLastPathComponent().appendingPathComponent("fake-model.partial").path))
        let steps = progress.byteSteps
        XCTAssertEqual(steps.first?.0, 0)
        XCTAssertEqual(steps.last?.0, spec.totalBytes)
        XCTAssertEqual(steps.map(\.0), steps.map(\.0).sorted())
        XCTAssertTrue(steps.allSatisfy { $0.1 == spec.totalBytes })
    }

    func testDownloadRefusesWhenTheDiskIsTooSmallAndFetchesNothing() async {
        let (spec, fetcher) = smallSpec()
        let downloader = SpeechModelDownloader(fetcher: fetcher, diskSpace: FixedDisk(bytes: 1_000))
        do {
            try await downloader.download(spec, wispDir: root, progress: { _, _ in })
            XCTFail("should refuse")
        } catch let error as SpeechModelError {
            XCTAssertEqual(error, .lowDisk(neededBytes: spec.totalBytes + SpeechModelLocation.diskMarginBytes, freeBytes: 1_000))
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(fetcher.fetched, [])
    }

    func testCorruptDownloadIsRejectedDeletedAndNeverMarkedInstalled() async throws {
        let (spec, fetcher) = smallSpec()
        fetcher.corrupt = ["vocab.json"]
        let downloader = SpeechModelDownloader(fetcher: fetcher, diskSpace: FixedDisk(bytes: 100_000_000_000))
        do {
            try await downloader.download(spec, wispDir: root, progress: { _, _ in })
            XCTFail("should reject")
        } catch let error as SpeechModelError {
            XCTAssertEqual(error, .hashMismatch(path: "vocab.json"))
        }
        XCTAssertFalse(SpeechModelLocation.isInstalled(spec, at: SpeechModelLocation.directory(for: spec, wispDir: root)))
        let staged = SpeechModelLocation.root(wispDir: root).appendingPathComponent("fake-model.partial/vocab.json.part")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
    }

    func testRetryKeepsFilesThatAlreadyVerifiedInsteadOfFetchingThemAgain() async throws {
        let (spec, fetcher) = smallSpec()
        fetcher.corrupt = ["vocab.json"]
        let downloader = SpeechModelDownloader(fetcher: fetcher, diskSpace: FixedDisk(bytes: 100_000_000_000))
        _ = try? await downloader.download(spec, wispDir: root, progress: { _, _ in })
        fetcher.corrupt = []
        let before = fetcher.fetched.count
        try await downloader.download(spec, wispDir: root, progress: { _, _ in })
        XCTAssertEqual(Array(fetcher.fetched.dropFirst(before)), ["vocab.json"])
        XCTAssertTrue(SpeechModelLocation.isInstalled(spec, at: SpeechModelLocation.directory(for: spec, wispDir: root)))
    }

    func testParakeetManifestIsPinnedAndHasRealSizes() {
        let spec = SpeechModelSpec.parakeetV3
        XCTAssertEqual(spec.repo, "FluidInference/parakeet-tdt-0.6b-v3-coreml")
        XCTAssertEqual(spec.revision.count, 40)
        XCTAssertEqual(spec.files.count, 20)
        XCTAssertEqual(spec.totalBytes, 632_169_729)
        XCTAssertTrue(spec.files.contains { $0.path == "parakeet_vocab.json" })
        XCTAssertTrue(spec.files.contains { $0.path == "Encoder_v2.mlmodelc/weights/weight.bin" && $0.size == 594_211_328 })
        XCTAssertEqual(
            spec.downloadURL(for: spec.files[0]).absoluteString,
            "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/\(spec.revision)/\(spec.files[0].path)"
        )
        for file in spec.files {
            switch file.hash {
            case .sha256(let value): XCTAssertEqual(value.count, 64)
            case .gitBlobSHA1(let value): XCTAssertEqual(value.count, 40)
            }
            XCTAssertEqual(file.expectedSHA256?.count, 64, file.path)
        }
        XCTAssertEqual(spec.files.filter { if case .gitBlobSHA1 = $0.hash { true } else { false } }.count, 8)
    }

    // MARK: brain export and presentation

    func testBrainExportWritesDatedSlugNoteAndAppendsTheIndexLineWhenThereIsAnIndex() throws {
        let note = root.appendingPathComponent("nota.md")
        try Data("# Alinhamento\n".utf8).write(to: note)
        let brain = root.appendingPathComponent("brain")
        try FileManager.default.createDirectory(at: brain.appendingPathComponent("meetings"), withIntermediateDirectories: true)
        try Data("# Índice\n".utf8).write(to: brain.appendingPathComponent("meetings/meetings-index.md"))
        let utc = TimeZone(identifier: "UTC")!
        let saved = try MeetingBrainExport.save(note: note, title: "Reunião: Orçamento 2027!", startedAt: t0, brain: brain, timeZone: utc)
        XCTAssertEqual(saved.lastPathComponent, "2027-01-15-08h00m-reuniao-orcamento-2027.md")
        let again = try MeetingBrainExport.save(note: note, title: "Reunião: Orçamento 2027!", startedAt: t0, brain: brain, timeZone: utc)
        XCTAssertEqual(again.lastPathComponent, "2027-01-15-08h00m-reuniao-orcamento-2027-2.md")
        let index = try String(contentsOf: brain.appendingPathComponent("meetings/meetings-index.md"), encoding: .utf8)
        XCTAssertTrue(index.contains("- [[2027-01-15-08h00m-reuniao-orcamento-2027]] — Reunião: Orçamento 2027!"))
        XCTAssertEqual(MeetingBrainExport.slug("???"), "reuniao")
        XCTAssertLessThanOrEqual(MeetingBrainExport.indexLine(name: "x", title: String(repeating: "a", count: 400)).count, 200)
    }

    func testBrainExportDoesNotCreateAnIndexThatTheBrainDoesNotHave() throws {
        let note = root.appendingPathComponent("nota.md")
        try Data("# X\n".utf8).write(to: note)
        let brain = root.appendingPathComponent("brain2")
        try MeetingBrainExport.save(note: note, title: "X", startedAt: t0, brain: brain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: brain.appendingPathComponent("meetings/meetings-index.md").path))
    }

    func testStatusBadgesFollowWhatTheUserSeesInTheList() {
        XCTAssertEqual(MeetingStatusBadge.make(status: .recording, working: false, hasNote: false).label, "gravando")
        XCTAssertEqual(MeetingStatusBadge.make(status: .transcribing, working: true, hasNote: false).label, "transcrevendo")
        XCTAssertEqual(MeetingStatusBadge.make(status: .interrupted, working: false, hasNote: false).label, "transcrevendo")
        XCTAssertEqual(MeetingStatusBadge.make(status: .transcribed, working: true, hasNote: false).label, "gerando nota")
        XCTAssertEqual(MeetingStatusBadge.make(status: .noted, working: false, hasNote: true), MeetingStatusBadge(label: "pronto", tone: .ready))
        XCTAssertEqual(MeetingStatusBadge.make(status: .failed, working: false, hasNote: false).tone, .failed)
    }

    func testRowModelFormatsDateDurationTitleAndFailure() {
        let utc = TimeZone(identifier: "UTC")!
        let folder = URL(fileURLWithPath: "/x/2027-01-15_08-00-00")
        var meta = RecordingMeta(startedAt: t0, durationSeconds: 3725, devices: .init(mic: nil, system: nil), status: .noted)
        var row = MeetingRowModel(entry: MeetingEntry(folder: folder, meta: meta, hasTranscript: true, hasNote: true), working: false, timeZone: utc)
        XCTAssertEqual(row.title, "Reunião de 15/01 às 08:00")
        XCTAssertEqual(row.dateText, "15/01 08:00")
        XCTAssertEqual(row.durationText, "1:02:05")
        XCTAssertEqual(row.badge.label, "pronto")
        meta.title = "Roadmap"
        meta.durationSeconds = nil
        meta.status = .failed
        meta.failure = "disco cheio"
        row = MeetingRowModel(entry: MeetingEntry(folder: folder, meta: meta, hasTranscript: false, hasNote: false), working: false, timeZone: utc)
        XCTAssertEqual(row.title, "Roadmap")
        XCTAssertEqual(row.durationText, "—")
        XCTAssertEqual(row.detail, "disco cheio")
    }

    func testScrollFollowerPinsToTheEndUntilTheUserScrollsBack() {
        var follower = ScrollFollower()
        XCTAssertTrue(follower.isPinned)
        follower.scrolled(distanceFromBottom: 300)
        XCTAssertFalse(follower.isPinned)
        XCTAssertTrue(follower.showsJumpButton)
        follower.scrolled(distanceFromBottom: 10)
        XCTAssertTrue(follower.isPinned)
        follower.scrolled(distanceFromBottom: 500)
        follower.jumpToEnd()
        XCTAssertFalse(follower.showsJumpButton)
    }

    func testRecordControlTitlesTimerAndEnabledState() {
        XCTAssertEqual(RecordControl(phase: .idle, elapsed: 99, canRecord: true), RecordControl(phase: .idle, elapsed: 0, canRecord: true))
        let recording = RecordControl(phase: .recording, elapsed: 65, canRecord: false)
        XCTAssertEqual(recording.title, "Parar")
        XCTAssertEqual(recording.timer, "1:05")
        XCTAssertTrue(recording.isEnabled)
        XCTAssertFalse(RecordControl(phase: .idle, elapsed: 0, canRecord: false).isEnabled)
        XCTAssertFalse(RecordControl(phase: .finishing, elapsed: 0, canRecord: true).isEnabled)
        XCTAssertEqual(LevelBar(level: 2, active: true).fraction, 1)
        XCTAssertEqual(LevelBar(level: 0.7, active: false).fraction, 0)
    }

    func testPermissionCardsAppearOnlyForDeniedSourcesInUse() {
        XCTAssertEqual(MeetingPermissions.cards(mic: .granted, system: .unknown, sources: .both), [])
        let both = MeetingPermissions.cards(mic: .denied, system: .denied, sources: .both)
        XCTAssertEqual(both.map(\.id), ["mic", "system"])
        XCTAssertEqual(both[1].settingsURL, MeetingPermissions.audioCaptureSettings)
        XCTAssertEqual(both[0].settingsURL, MeetingPermissions.microphoneSettings)
        XCTAssertEqual(MeetingPermissions.cards(mic: .denied, system: .denied, sources: .mic).map(\.id), ["mic"])
        XCTAssertEqual(MeetingPermissions.cards(mic: .denied, system: .denied, sources: .system).map(\.id), ["system"])
        XCTAssertEqual(
            MeetingPermissions.hint(mic: .notDetermined, system: .unknown, sources: .both),
            "O macOS vai pedir permissão para o microfone e o áudio do Mac na primeira gravação."
        )
        XCTAssertNil(MeetingPermissions.hint(mic: .granted, system: .granted, sources: .both))
    }

    func testNoteTitleComesFromTheFirstHeading() {
        XCTAssertEqual(MeetingNoteText.title(of: "---\ntipo: reuniao\n---\n\n# Plano de lançamento\n\n## Resumo\n"), "Plano de lançamento")
        XCTAssertNil(MeetingNoteText.title(of: "## Só subtítulo\n"))
    }

    // MARK: review fixes

    private final class CountingNotes: MeetingNoteWriter, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls = 0

        func writeNote(folder: URL) async throws -> NoteOutcome {
            lock.withLock { calls += 1 }
            try Data("# T\n".utf8).write(to: RecordingFolder.noteURL(in: folder))
            return NoteOutcome(generated: true, title: "T")
        }
    }

    func testProcessingANotedMeetingAgainDoesNothingButRegenerateStillWorks() async throws {
        let folder = try makeRecording(status: .transcribing)
        let recognizer = ScriptedRecognizer()
        let notes = CountingNotes()
        let flow = pipeline(recognizer, notes: notes)
        try await flow.process(folder: folder)
        let before = (recognizer.seen.count, notes.calls)
        let stamp = try Data(contentsOf: MeetingTranscriptFile.url(in: folder))
        try await flow.process(folder: folder)
        XCTAssertEqual(recognizer.seen.count, before.0)
        XCTAssertEqual(notes.calls, before.1)
        XCTAssertEqual(try Data(contentsOf: MeetingTranscriptFile.url(in: folder)), stamp)
        try await flow.regenerateNote(folder: folder)
        XCTAssertEqual(notes.calls, before.1 + 1)
    }

    func testFinalPassWaitsOnThePauseGateBeforeEveryRecognizerCall() async throws {
        let folder = try makeRecording(status: .transcribing)
        let gate = UpdateLog()
        let recognizer = ScriptedRecognizer()
        let transcriber = MeetingTranscriber(
            recognizer: recognizer, config: ChannelStreamerConfig(windowSeconds: 4, overlapSeconds: 1, emitsPartials: false),
            pause: { gate.note("tick") }
        )
        _ = try await transcriber.transcribe(folder: folder, startedAt: t0, duration: 9)
        XCTAssertEqual(gate.notes.count, recognizer.seen.count)
        XCTAssertGreaterThan(gate.notes.count, 0)
    }

    private actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters = []
        }
    }

    private final class SlowRecognizer: SpeechRecognizer, @unchecked Sendable {
        let engineName = "slow"
        let gate = Gate()
        private let lock = NSLock()
        private var calls: [Int] = []
        var sizes: [Int] { lock.withLock { calls } }

        func transcribe(_ samples: [Float], language: String?) async throws -> [RecognizedSpan] {
            lock.withLock { calls.append(samples.count) }
            await gate.wait()
            return [RecognizedSpan(text: "t\(samples.count)x\(lock.withLock { calls.count })", start: 0, end: 1)]
        }
    }

    func testLiveQueueKeepsFinalsDropsPartialsAndReportsLagWhenTheRecognizerFallsBehind() async {
        let recognizer = SlowRecognizer()
        let lag = UpdateLog()
        let store = MeetingTranscriptStore(startedAt: t0, engine: "slow")
        let live = LiveTranscriber(recognizer: recognizer, store: store, onUpdate: { _ in }, onLag: { lag.flag($0) })
        for _ in 0..<26 { live.push16k(tone(seconds: 1), channel: .mic) }
        XCTAssertTrue(lag.flags.contains(true))
        await recognizer.gate.open()
        let result = await live.finish()
        XCTAssertEqual(lag.flags.last, false)
        XCTAssertGreaterThanOrEqual(result.filter { $0.isFinal }.count, 5)
        XCTAssertLessThanOrEqual(recognizer.sizes.filter { $0 < 80_000 }.count, 3)
    }

    func testStopAndWaitReturnsOnlyAfterTheWorkerIsDoneAndNothingIsCommittedLater() async throws {
        let recognizer = SlowRecognizer()
        let store = MeetingTranscriptStore(startedAt: t0, engine: "slow", folder: root)
        let live = LiveTranscriber(recognizer: recognizer, store: store, onUpdate: { _ in })
        for _ in 0..<6 { live.push16k(tone(seconds: 1), channel: .mic) }
        Task { try? await Task.sleep(for: .milliseconds(100)); await recognizer.gate.open() }
        await live.stopAndWait()
        let count = store.finals.count
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(store.finals.count, count)
        XCTAssertLessThanOrEqual(count, 1)
    }

    func testAlignerAnchorsBothChannelsToOneOriginAndFillsGapsAndDropsOverlap() {
        let aligner = LiveAudioAligner()
        let rate = Double(CaptureFormat.sampleRate)
        XCTAssertEqual(aligner.align([Float](repeating: 1, count: 4_800), channel: .mic, at: 100).samples.count, 4_800)
        let system = aligner.align([Float](repeating: 2, count: 4_800), channel: .system, at: 101)
        XCTAssertEqual(system.samples.count, Int(rate) + 4_800)
        XCTAssertEqual(system.samples.prefix(Int(rate)).reduce(0, +), 0)
        XCTAssertNil(system.gapSeconds)
        let jitter = aligner.align([Float](repeating: 1, count: 480), channel: .mic, at: 100 + 4_800 / rate + 0.01)
        XCTAssertEqual(jitter.samples.count, 480)
        let gap = aligner.align([Float](repeating: 1, count: 480), channel: .mic, at: 100 + 4_800 / rate + 480 / rate + 0.5)
        XCTAssertEqual(gap.samples.count, 480 + Int(0.5 * rate), accuracy: 2)
        let overlap = aligner.align([Float](repeating: 3, count: 4_800), channel: .system, at: 101.05)
        XCTAssertEqual(overlap.samples.count, 2_400)
        let early = LiveAudioAligner()
        _ = early.align([1], channel: .mic, at: 50)
        XCTAssertEqual(early.align([Float](repeating: 1, count: 4_800), channel: .system, at: 49.9).samples.count, 0)
    }

    func testAlignerNeverAllocatesMoreThanTwoSecondsOfZerosAndReportsTheGapInstead() {
        let aligner = LiveAudioAligner()
        _ = aligner.align([Float](repeating: 1, count: 480), channel: .mic, at: 10)
        let late = aligner.align([Float](repeating: 1, count: 480), channel: .mic, at: 10 + 600)
        XCTAssertEqual(late.samples.count, 480)
        XCTAssertEqual(try XCTUnwrap(late.gapSeconds), 600 - 0.01, accuracy: 0.05)
        let next = aligner.align([Float](repeating: 1, count: 480), channel: .mic, at: 10 + 600 + 480.0 / 48_000)
        XCTAssertEqual(next.samples.count, 480)
        XCTAssertNil(next.gapSeconds)
        let lateStart = LiveAudioAligner()
        _ = lateStart.align([1], channel: .mic, at: 0)
        let system = lateStart.align([Float](repeating: 1, count: 480), channel: .system, at: 3600)
        XCTAssertEqual(system.samples.count, 480)
        XCTAssertNotNil(system.gapSeconds)
    }

    func testSkipGapKeepsTheTimelineWithoutBufferingSilenceAndFlushesWhatWasHeard() {
        var streamer = ChannelStreamer(channel: .mic)
        _ = streamer.append(tone(seconds: 2))
        let flushed = streamer.skipGap(samples: 16_000 * 600)
        XCTAssertEqual(flushed.map(\.startSeconds), [0])
        XCTAssertEqual(streamer.totalSamples, 16_000 * 602)
        let jobs = streamer.append(tone(seconds: 5))
        XCTAssertEqual(jobs.filter { $0.kind == .final }.map(\.startSeconds), [602])
    }

    func testPauseGateThatThrowsStopsTheFinalPassWithCancellation() async throws {
        let folder = try makeRecording(status: .transcribing)
        let recognizer = ScriptedRecognizer()
        let transcriber = MeetingTranscriber(
            recognizer: recognizer, config: ChannelStreamerConfig(windowSeconds: 4, overlapSeconds: 1, emitsPartials: false),
            pause: { throw CancellationError() }
        )
        do {
            _ = try await transcriber.transcribe(folder: folder, startedAt: t0, duration: 9)
            XCTFail("should cancel")
        } catch is CancellationError {}
        XCTAssertEqual(recognizer.seen.count, 0)
    }

    func testSystemSilenceIsNeverPersistedAndClearsWhenSoundArrives() {
        var watch = SystemAudioWatch(stored: .denied)
        XCTAssertEqual(watch.state, .unknown)
        watch.observe(level: 0, silentWarning: true)
        XCTAssertTrue(watch.silentNow)
        XCTAssertEqual(watch.state, .unknown)
        XCTAssertFalse(watch.shouldPersist)
        watch.observe(level: 0.3, silentWarning: false)
        XCTAssertFalse(watch.silentNow)
        XCTAssertEqual(watch.state, .granted)
        XCTAssertTrue(watch.shouldPersist)
        watch.observe(level: 0, silentWarning: true)
        XCTAssertFalse(watch.silentNow)
        var again = SystemAudioWatch(stored: .unknown)
        again.observe(level: 0, silentWarning: true)
        again.startRecording()
        XCTAssertFalse(again.silentNow)
        XCTAssertEqual(SystemAudioWatch(stored: .granted).state, .granted)
    }

    func testSilenceShowsANeutralHintWithTheSettingsButtonNotARedCard() {
        let hint = MeetingPermissions.silenceHint(sources: .both, silent: true)
        XCTAssertEqual(hint?.neutral, true)
        XCTAssertEqual(hint?.settingsURL, MeetingPermissions.audioCaptureSettings)
        XCTAssertEqual(hint?.buttonTitle, "Abrir Ajustes do Sistema")
        XCTAssertNil(MeetingPermissions.silenceHint(sources: .mic, silent: true))
        XCTAssertNil(MeetingPermissions.silenceHint(sources: .both, silent: false))
        XCTAssertEqual(MeetingPermissions.cards(mic: .granted, system: .unknown, sources: .both), [])
        XCTAssertFalse(MeetingPermissions.cards(mic: .denied, system: .denied, sources: .both).contains { $0.neutral })
    }

    func testVerifyIgnoresTheMarkerAndChecksTheCompiledManifestForBothHashKinds() async throws {
        let (spec, fetcher) = smallSpec()
        try await SpeechModelDownloader(fetcher: fetcher, diskSpace: FixedDisk(bytes: 100_000_000_000))
            .download(spec, wispDir: root, progress: { _, _ in })
        let target = SpeechModelLocation.directory(for: spec, wispDir: root)
        XCTAssertTrue(SpeechModelLocation.verify(spec, at: target))
        for path in ["vocab.json", "Enc.mlmodelc/weights/weight.bin"] {
            let file = target.appendingPathComponent(path)
            let original = try Data(contentsOf: file)
            var bytes = original
            bytes[0] ^= 0x01
            try bytes.write(to: file)
            let forged = SpeechModelLocation.Marker(
                revision: spec.revision,
                sha256: Dictionary(uniqueKeysWithValues: try spec.files.map {
                    ($0.path, try FileDigest.sha256(of: target.appendingPathComponent($0.path)))
                })
            )
            try JSONEncoder().encode(forged).write(to: target.appendingPathComponent(SpeechModelLocation.verifiedMarker))
            XCTAssertTrue(SpeechModelLocation.isInstalled(spec, at: target), path)
            XCTAssertFalse(SpeechModelLocation.verify(spec, at: target), path)
            try original.write(to: file)
        }
    }

    func testModelMarkerHoldsSHA256OfEveryFileAndVerifyCatchesASilentChange() async throws {
        let (spec, fetcher) = smallSpec()
        let downloader = SpeechModelDownloader(fetcher: fetcher, diskSpace: FixedDisk(bytes: 100_000_000_000))
        try await downloader.download(spec, wispDir: root, progress: { _, _ in })
        let target = SpeechModelLocation.directory(for: spec, wispDir: root)
        let marker = try XCTUnwrap(SpeechModelLocation.readMarker(at: target))
        XCTAssertEqual(Set(marker.sha256.keys), Set(spec.files.map(\.path)))
        XCTAssertTrue(marker.sha256.values.allSatisfy { $0.count == 64 })
        XCTAssertTrue(SpeechModelLocation.verify(spec, at: target))
        let file = target.appendingPathComponent("vocab.json")
        var bytes = try Data(contentsOf: file)
        bytes[0] ^= 0x01
        try bytes.write(to: file)
        XCTAssertTrue(SpeechModelLocation.isInstalled(spec, at: target))
        XCTAssertFalse(SpeechModelLocation.verify(spec, at: target))
    }

    func testAFailedSwapKeepsTheWorkingModelAndLeavesNoBackupOnSuccess() async throws {
        let (spec, fetcher) = smallSpec()
        let disk = FixedDisk(bytes: 100_000_000_000)
        try await SpeechModelDownloader(fetcher: fetcher, diskSpace: disk).download(spec, wispDir: root, progress: { _, _ in })
        let target = SpeechModelLocation.directory(for: spec, wispDir: root)
        try await SpeechModelDownloader(fetcher: fetcher, diskSpace: disk).download(spec, wispDir: root, progress: { _, _ in })
        XCTAssertTrue(SpeechModelLocation.verify(spec, at: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathExtension("backup").path))
        let calls = CallCounter()
        let failing = SpeechModelDownloader(fetcher: fetcher, diskSpace: disk, move: { from, to in
            if calls.next() == 2 { throw SpeechModelError.io("disco cheio") }
            try FileManager.default.moveItem(at: from, to: to)
        })
        do {
            try await failing.download(spec, wispDir: root, progress: { _, _ in })
            XCTFail("should fail")
        } catch {}
        XCTAssertTrue(SpeechModelLocation.verify(spec, at: target))
    }

    func testManifestPathsMustStayInsideTheModelFolder() async {
        for bad in ["../evil", "/etc/passwd", "a/../../b", "a//b", "", "a\\b", "./x"] {
            var spec = SpeechModelSpec.parakeetV3
            spec.files = [SpeechModelFile(path: bad, size: 1, hash: .sha256(String(repeating: "0", count: 64)))]
            XCTAssertThrowsError(try spec.validate(), bad) { XCTAssertEqual($0 as? SpeechModelError, .badPath(bad)) }
            let downloader = SpeechModelDownloader(fetcher: MemoryFetcher(contents: [:]), diskSpace: FixedDisk(bytes: 100_000_000_000))
            do {
                try await downloader.download(spec, wispDir: root, progress: { _, _ in })
                XCTFail("should refuse \(bad)")
            } catch {}
        }
        XCTAssertNoThrow(try SpeechModelSpec.parakeetV3.validate())
    }

    func testAGitPinnedFileMustAlsoMatchItsPinnedSHA256() async throws {
        var (spec, fetcher) = gitOnlyPinnedSpec()
        let downloader = SpeechModelDownloader(fetcher: fetcher, diskSpace: FixedDisk(bytes: 100_000_000_000))
        try await downloader.download(spec, wispDir: root, progress: { _, _ in })
        XCTAssertTrue(SpeechModelLocation.verify(spec, at: SpeechModelLocation.directory(for: spec, wispDir: root)))
        spec.files[0].sha256 = String(repeating: "0", count: 64)
        XCTAssertFalse(SpeechModelLocation.verify(spec, at: SpeechModelLocation.directory(for: spec, wispDir: root)))
        let other = root.appendingPathComponent("other")
        do {
            try await downloader.download(spec, wispDir: other, progress: { _, _ in })
            XCTFail("sha256 mismatch must be refused")
        } catch let error as SpeechModelError {
            XCTAssertEqual(error, .hashMismatch(path: "vocab.json"))
        }
        fetcher = MemoryFetcher(contents: [:])
    }

    func testABusyNoteIsNotTurnedIntoARawNoteAndTheMeetingStaysWaiting() async throws {
        struct Busy: MeetingNoteWriter {
            func writeNote(folder: URL) async throws -> NoteOutcome { throw MeetingNoteBusy() }
        }
        let folder = try makeRecording(status: .transcribing)
        do {
            try await pipeline(notes: Busy()).process(folder: folder)
            XCTFail("busy must surface")
        } catch is MeetingNoteBusy {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingFolder.noteURL(in: folder).path))
        let meta = try RecordingFolder.read(in: folder)
        XCTAssertEqual(meta.status, .transcribed)
        XCTAssertNil(meta.failure)
    }

    func testCancellingARunningCommandKillsTheWholeProcessGroupAndReportsIt() async throws {
        let marker = root.appendingPathComponent("child-alive")
        let script = "sleep 30 & echo $! > '\(marker.path)'; wait"
        let token = CommandCancellation()
        let started = Task.detached {
            CommandRunner.run(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], timeout: 60, cancellation: token)
        }
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(for: .milliseconds(50)) }
        let child = Int32(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        XCTAssertGreaterThan(child, 0)
        XCTAssertEqual(kill(child, 0), 0)
        token.cancel()
        let finished = await started.value
        let result = try finished.get()
        XCTAssertEqual(result.status, -2)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(kill(child, 0), -1)
    }

    func testACommandCancelledBeforeItStartedIsStoppedAsSoonAsItRegisters() throws {
        let token = CommandCancellation()
        token.cancel()
        let result = try CommandRunner.run(
            executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 60, cancellation: token
        ).get()
        XCTAssertEqual(result.status, -2)
    }

    private final class UnloadCounter: SpeechRecognizer, @unchecked Sendable {
        let engineName = "u"
        private let lock = NSLock()
        private(set) var unloads = 0
        func transcribe(_ samples: [Float], language: String?) async throws -> [RecognizedSpan] { [] }
        func unload() async { lock.withLock { unloads += 1 } }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var on = true
        var value: Bool { lock.withLock { on } }
        func clear() { lock.withLock { on = false } }
    }

    func testThePauseGateReleasesTheFinalPassModelOnceWhileARecordingRuns() async throws {
        let recognizer = UnloadCounter()
        let flag = Flag()
        let gate = MeetingPauseGate(recognizer: recognizer, interval: .milliseconds(20), isRecording: { flag.value })
        Task { try? await Task.sleep(for: .milliseconds(120)); flag.clear() }
        try await gate.wait()
        XCTAssertEqual(recognizer.unloads, 1)
        try await gate.wait()
        XCTAssertEqual(recognizer.unloads, 1)
    }

    func testThePauseGateStopsWaitingWhenCancelled() async {
        let recognizer = UnloadCounter()
        let gate = MeetingPauseGate(recognizer: recognizer, interval: .milliseconds(20), isRecording: { true })
        let waiting = Task { try await gate.wait() }
        try? await Task.sleep(for: .milliseconds(80))
        waiting.cancel()
        do {
            try await waiting.value
            XCTFail("should cancel")
        } catch is CancellationError {} catch { XCTFail("\(error)") }
    }

    func testAttributionNamesTheAuthorTheLicenseAndTheChange() {
        let text = SpeechModelSpec.attribution
        XCTAssertTrue(text.contains("NVIDIA"))
        XCTAssertTrue(text.contains("CC-BY-4.0"))
        XCTAssertTrue(text.contains("FluidInference"))
    }

    func testIndexLineIsSanitizedAndASymlinkedMeetingsFolderOutsideTheBrainIsRefused() throws {
        let nasty = "Plano ]] [[outro|alias\r\nfim"
        XCTAssertEqual(MeetingBrainExport.sanitizedTitle(nasty), "Plano outro alias fim")
        let line = MeetingBrainExport.indexLine(name: "x", title: nasty)
        XCTAssertFalse(line.contains("|") || line.contains("\n") || line.contains("\r"))
        XCTAssertEqual(line.components(separatedBy: "[[").count, 2)
        XCTAssertEqual(line.components(separatedBy: "]]").count, 2)
        let note = root.appendingPathComponent("nota.md")
        try Data("# X\n".utf8).write(to: note)
        let outside = root.appendingPathComponent("outside")
        let brain = root.appendingPathComponent("brain3")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: brain, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: brain.appendingPathComponent("meetings"), withDestinationURL: outside)
        XCTAssertThrowsError(try MeetingBrainExport.save(note: note, title: "X", startedAt: t0, brain: brain)) {
            XCTAssertEqual($0 as? MeetingBrainExportError, .outsideBrain("meetings"))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }
}

private final class UpdateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [[MeetingSegment]] = []
    private(set) var notes: [String] = []
    private(set) var stages: [MeetingStage] = []
    private(set) var byteSteps: [(Int64, Int64)] = []

    var all: [[MeetingSegment]] { lock.withLock { updates } }
    func add(_ value: [MeetingSegment]) { lock.withLock { updates.append(value) } }
    func note(_ value: String) { lock.withLock { notes.append(value) } }
    func stage(_ value: MeetingStage) { lock.withLock { stages.append(value) } }
    func bytes(_ a: Int64, _ b: Int64) { lock.withLock { byteSteps.append((a, b)) } }
    private(set) var flags: [Bool] = []
    func flag(_ value: Bool) { lock.withLock { flags.append(value) } }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}
