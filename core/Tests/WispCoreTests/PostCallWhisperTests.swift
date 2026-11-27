import AVFoundation
import XCTest
@testable import WispCore

private struct IdleRecognizer: SpeechRecognizer {
    let engineName = "parakeet-test"
    func transcribe(_ samples: [Float], language: String?) async throws -> [RecognizedSpan] { [] }
}

private struct StubNoteWriter: MeetingNoteWriter {
    func writeNote(folder: URL) async throws -> NoteOutcome {
        try Data("# Reunião\n".utf8).write(to: RecordingFolder.noteURL(in: folder))
        return NoteOutcome(generated: true, title: "Reunião")
    }
}

final class PostCallWhisperTests: XCTestCase {
    private var root: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("postcall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testSettingsDefaults() {
        let meetings = MeetingSettings()
        XCTAssertEqual(meetings.language, .pt)
        XCTAssertEqual(meetings.postCallEngine, .whisperLargeV3)
        XCTAssertEqual(MeetingLanguage.pt.label, "Português (BR)")
    }

    func testOldSettingsWithoutTheFieldsDecodeToDefaults() throws {
        let old = #"{"webhookEnabled":true,"limitMinutes":60,"autoSummary":false,"echoCancel":"never","cleanupDays":7}"#
        let decoded = try JSONDecoder().decode(MeetingSettings.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.language, .pt)
        XCTAssertEqual(decoded.postCallEngine, .whisperLargeV3)
        XCTAssertEqual(decoded.limitMinutes, 60)
        XCTAssertFalse(decoded.autoSummary)
    }

    func testSettingsRoundTripAndUnknownValueFallsBack() throws {
        var meetings = MeetingSettings()
        meetings.language = .es
        meetings.postCallEngine = .off
        let again = try JSONDecoder().decode(MeetingSettings.self, from: JSONEncoder().encode(meetings))
        XCTAssertEqual(again.language, .es)
        XCTAssertEqual(again.postCallEngine, .off)
        let odd = try JSONDecoder().decode(MeetingSettings.self, from: Data(#"{"language":"klingon","postCallEngine":"x"}"#.utf8))
        XCTAssertEqual(odd.language, .pt)
        XCTAssertEqual(odd.postCallEngine, .whisperLargeV3)
    }

    func testWhisperJSONParsesToSpansWithSeconds() throws {
        let json = #"""
        {"transcription":[
          {"timestamps":{"from":"00:00:01,500","to":"00:00:04,000"},"offsets":{"from":1500,"to":4000},"text":" Então eu tô no projeto X."},
          {"timestamps":{"from":"00:00:05,000","to":"00:00:06,250"},"offsets":{"from":5000,"to":6250},"text":" Beleza."}]}
        """#
        let spans = try WhisperOutput.parse(Data(json.utf8))
        XCTAssertEqual(spans.map(\.text), [" Então eu tô no projeto X.", " Beleza."])
        XCTAssertEqual(spans[0].start, 1.5)
        XCTAssertEqual(spans[1].end, 6.25)
    }

    func testChannelsMergeByTimeWithSpeakerAttribution() throws {
        var merger = TranscriptMerger()
        merger.commit([RecognizedSpan(text: "Oi, tudo bem?", start: 0, end: 2)], channel: .system)
        merger.commit([RecognizedSpan(text: "Tudo ótimo.", start: 3, end: 4)], channel: .mic)
        merger.commit([RecognizedSpan(text: "Vamos começar.", start: 6, end: 8)], channel: .system)
        let segments = TranscriptTidy.mergeAdjacent(merger.finals)
        XCTAssertEqual(segments.map(\.speaker), ["outros", "eu", "outros"])
        XCTAssertEqual(segments.map(\.speakerName), ["Outros", "Você", "Outros"])
    }

    func testFilterDropsInventedPhrasesAndKeepsRealSpeech() {
        let loud = ChannelEnvelope(meanSquares: Array(repeating: 0.01, count: 100))
        let spans = [
            RecognizedSpan(text: "Legenda por Sônia Ruberti", start: 0, end: 2),
            RecognizedSpan(text: "Legendas pela comunidade Amara.org", start: 2, end: 4),
            RecognizedSpan(text: "Se inscreva no canal e ative o sininho.", start: 4, end: 6),
            RecognizedSpan(text: "Obrigado por assistir!", start: 6, end: 8),
            RecognizedSpan(text: "Então eu tô no projeto X ou no deal X.", start: 8, end: 12),
            RecognizedSpan(text: "Tchau, tchau.", start: 12, end: 13),
        ]
        let result = WhisperHallucination.filter(spans, envelope: loud)
        XCTAssertEqual(result.kept.map(\.text), ["Então eu tô no projeto X ou no deal X.", "Tchau, tchau."])
        XCTAssertEqual(result.dropped, 4)
    }

    func testLoneFillersGoOnlyOverSilence() {
        let silent = ChannelEnvelope(meanSquares: Array(repeating: 0, count: 20))
        let loud = ChannelEnvelope(meanSquares: Array(repeating: 0.01, count: 20))
        let spans = [RecognizedSpan(text: "Tchau, tchau.", start: 1, end: 2), RecognizedSpan(text: "E aí", start: 3, end: 4)]
        XCTAssertEqual(WhisperHallucination.filter(spans, envelope: silent).kept.count, 0)
        XCTAssertEqual(WhisperHallucination.filter(spans, envelope: loud).kept.count, 2)
    }

    func testRepeatedLineCollapsesFromThreeInARow() {
        let loud = ChannelEnvelope(meanSquares: Array(repeating: 0.01, count: 100))
        func line(_ text: String, _ at: Double) -> RecognizedSpan { RecognizedSpan(text: text, start: at, end: at + 1) }
        let spans = [line("Bom.", 0), line("Bom.", 1), line("Bom.", 2), line("Bom.", 3), line("Sim.", 4), line("Sim.", 5), line("Certo.", 6)]
        let result = WhisperHallucination.filter(spans, envelope: loud)
        XCTAssertEqual(result.kept.map(\.text), ["Bom.", "Sim.", "Sim.", "Certo."])
        XCTAssertEqual(result.dropped, 3)
    }

    func testAutoLanguageStillPassesDetectionFlag() {
        let model = URL(fileURLWithPath: "/m/ggml.bin")
        let input = URL(fileURLWithPath: "/t/mic.wav")
        let base = URL(fileURLWithPath: "/t/mic")
        let auto = WhisperCommand.arguments(model: model, language: .auto, input: input, outputBase: base)
        let index = try? XCTUnwrap(auto.firstIndex(of: "-l"))
        XCTAssertEqual(index.map { auto[$0 + 1] }, "auto")
        let pt = WhisperCommand.arguments(model: model, language: .pt, input: input, outputBase: base)
        XCTAssertEqual(pt[(pt.firstIndex(of: "-l") ?? 0) + 1], "pt")
        XCTAssertFalse(pt.contains("--vad"))
        XCTAssertEqual(pt.last, input.path)
    }

    func testBinaryLookupUsesPathAndReportsMissing() throws {
        XCTAssertNil(WhisperLocator.binary(searchPATH: root.path, fallback: []))
        let binary = root.appendingPathComponent("whisper-cli")
        try Data("#!/bin/sh\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        XCTAssertEqual(WhisperLocator.binary(searchPATH: "/nowhere:\(root.path)", fallback: [])?.path, binary.path)
    }

    private func makeFolder(language: String? = "pt") throws -> URL {
        let folder = root.appendingPathComponent("rec", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var meta = RecordingMeta(startedAt: t0, durationSeconds: 60, devices: .init(mic: nil, system: nil), status: .transcribed)
        meta.language = language
        try RecordingFolder.write(meta, in: folder)
        let document = MeetingTranscriptDocument(
            startedAt: t0, durationSeconds: 60, engine: "parakeet-test",
            segments: [MeetingSegment(start: 0, end: 3, speaker: "outros", text: "hello there")]
        )
        try MeetingTranscriptFile.write(document, in: folder)
        return folder
    }

    private func pipeline(engine: PostCallEngine, wispDir: URL) -> MeetingPipeline {
        MeetingPipeline(
            transcriber: MeetingTranscriber(recognizer: IdleRecognizer()), notes: StubNoteWriter(),
            refiner: { recorded in
                PostCallRefiner(
                    engine: engine, language: recorded.flatMap(MeetingLanguage.init(rawValue:)) ?? .pt, wispDir: wispDir,
                    searchPATH: { "" }, isRecording: { false }
                )
            }
        )
    }

    func testMissingModelKeepsParakeetTranscriptSetsNoticeAndStillWritesNote() async throws {
        let folder = try makeFolder()
        try await pipeline(engine: .whisperTurbo, wispDir: root.appendingPathComponent("empty-wisp")).process(folder: folder)
        let document = try MeetingTranscriptFile.read(in: folder)
        XCTAssertEqual(document.engine, "parakeet-test")
        XCTAssertEqual(document.segments.map(\.text), ["hello there"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: MeetingTranscriptFile.parakeetBackupURL(in: folder).path))
        let meta = try RecordingFolder.read(in: folder)
        XCTAssertNotNil(meta.notice)
        XCTAssertEqual(meta.status, .noted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingFolder.noteURL(in: folder).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(PostCallRefiner.tempFolderName).path))
    }

    func testEngineOffDoesNothingToTheTranscript() async throws {
        let folder = try makeFolder()
        try await pipeline(engine: .off, wispDir: root).process(folder: folder)
        XCTAssertNil(try RecordingFolder.read(in: folder).notice)
        XCTAssertEqual(try MeetingTranscriptFile.read(in: folder).engine, "parakeet-test")
    }

    func testLoopInsideOneLineCollapsesToOneCopy() {
        let looped = "Então fíjó, é, fíjó, é, fíjó, é, fíjó, é, fíjó, é, fíjó, é, acabou"
        XCTAssertEqual(WhisperHallucination.collapseLoops(looped), "Então fíjó, é, acabou")
        XCTAssertEqual(WhisperHallucination.collapseLoops("bom bom bom bom bom"), "bom")
        let real = "Eu acho, eu acho que sim, sim, sim, tá bom."
        XCTAssertEqual(WhisperHallucination.collapseLoops(real), real)
        let loud = ChannelEnvelope(meanSquares: Array(repeating: 0.01, count: 20))
        let kept = WhisperHallucination.filter([RecognizedSpan(text: looped, start: 0, end: 5)], envelope: loud).kept
        XCTAssertEqual(kept.map(\.text), ["Então fíjó, é, acabou"])
    }

    func testNordicGibberishIsDroppedForPortugueseAndSpanishOnly() {
        let loud = ChannelEnvelope(meanSquares: Array(repeating: 0.01, count: 20))
        let spans = [
            RecognizedSpan(text: "Hvað var aftur að toga að liga?", start: 0, end: 2),
            RecognizedSpan(text: "Ég hefði að þetta er að vera.", start: 2, end: 4),
            RecognizedSpan(text: "Então eu tô no projeto X ou no deal X.", start: 4, end: 6),
            RecognizedSpan(text: "A Björk mandou o link, senha e login.", start: 6, end: 8),
            RecognizedSpan(text: "Beleza, a gente vê isso depois do almoço, tá?", start: 8, end: 10),
            RecognizedSpan(text: "A Vera falou com a Vera.", start: 10, end: 12),
        ]
        XCTAssertEqual(WhisperHallucination.filter(spans, envelope: loud, language: .pt).kept.map(\.text), Array(spans[2...].map(\.text)))
        XCTAssertEqual(WhisperHallucination.filter(spans, envelope: loud, language: .es).kept.count, 4)
        XCTAssertEqual(WhisperHallucination.filter(spans, envelope: loud, language: .en).kept.count, 6)
    }

    func testArgumentsKeepWindowsIndependent() {
        let args = WhisperCommand.arguments(
            model: URL(fileURLWithPath: "/m.bin"), language: .pt, input: URL(fileURLWithPath: "/a.wav"), outputBase: URL(fileURLWithPath: "/a")
        )
        XCTAssertEqual(args[(args.firstIndex(of: "-mc") ?? 0) + 1], "0")
    }

    func testExportKeepsEachChannelOnItsOwnWAVWithTheRightLevelAndLength() async throws {
        let rate = 48_000.0
        let frames = AVAudioFrameCount(4 * rate)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for index in 0..<Int(frames) {
            data[0][index] = 0.5 * sin(Float(index) * 0.05)
            data[1][index] = Double(index) / rate >= 2 ? 0.1 * sin(Float(index) * 0.2) : 0
        }
        let audio = root.appendingPathComponent("audio.caf")
        try AVAudioFile(forWriting: audio, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        ], commonFormat: .pcmFormatFloat32, interleaved: false).write(from: buffer)

        let exports = try await PostCallRefiner.export(audio: audio, channels: AudioChannel.allCases, into: root)
        func samples(_ channel: AudioChannel) throws -> [Float] {
            let wav = try Data(contentsOf: XCTUnwrap(exports[channel]).url)
            XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
            let rateField = wav[24..<28].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
            XCTAssertEqual(rateField, 16_000)
            return stride(from: 44, to: wav.count - 1, by: 2).map {
                Float(Int16(bitPattern: UInt16(wav[$0]) | UInt16(wav[$0 + 1]) << 8)) / 32768
            }
        }
        let mic = try samples(.mic)
        let system = try samples(.system)
        XCTAssertEqual(Double(mic.count), 4 * 16_000, accuracy: 200)
        XCTAssertEqual(Double(system.count), 4 * 16_000, accuracy: 200)
        // mic: 0.5 sine everywhere (rms 0.354); system: silent for 2 s, then 0.1 sine (rms 0.0707)
        XCTAssertEqual(SignalLevel.rms(mic), 0.354, accuracy: 0.03)
        XCTAssertEqual(SignalLevel.rms(Array(system.prefix(30_000))), 0, accuracy: 0.001)
        XCTAssertEqual(SignalLevel.rms(Array(system.suffix(30_000))), 0.0707, accuracy: 0.01)
        let envelope = try XCTUnwrap(exports[.system]).envelope
        XCTAssertLessThan(envelope.rms(from: 0, to: 1.5), WhisperHallucination.silenceRMS)
        XCTAssertGreaterThan(envelope.rms(from: 2.5, to: 3.5), 0.05)
    }
}
