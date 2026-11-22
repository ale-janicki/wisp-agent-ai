import AVFoundation
import XCTest
@testable import WispCore

private final class CountingRecognizer: SpeechRecognizer, @unchecked Sendable {
    let engineName = "counting"
    let invents: Bool
    private let lock = NSLock()
    private var sizes: [Int] = []

    init(invents: Bool) { self.invents = invents }

    var calls: [Int] { lock.withLock { sizes } }

    func transcribe(_ samples: [Float], language: String?) async throws -> [RecognizedSpan] {
        let number = lock.withLock { () -> Int in
            sizes.append(samples.count)
            return sizes.count
        }
        guard invents else { return [] }
        return [RecognizedSpan(text: "fala\(number)", start: 0, end: Double(samples.count) / 16_000)]
    }
}

final class NoiseRangesTests: XCTestCase {
    private var root: URL!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("noise-ranges-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func pinkNoise(seconds: Int, rms target: Float) -> [Float] {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Float {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: state >> 11) % 2_000_001) / 1_000_000 - 1
        }
        var rows = [Float](repeating: 0, count: 8)
        var out = [Float](repeating: 0, count: seconds * 16_000)
        for index in 0..<out.count {
            let row = (index + 1).trailingZeroBitCount
            if row < rows.count { rows[row] = next() }
            out[index] = rows.reduce(0, +) + next()
        }
        let level = SignalLevel.rms(out)
        return out.map { $0 * target / level }
    }

    private func syllables(seconds: Int) -> [Float] {
        (0..<(seconds * 16_000)).map { index in
            let time = Double(index) / 16_000
            let phase = time.truncatingRemainder(dividingBy: 0.25)
            let envelope = phase < 0.15 ? Float(sin(Double.pi * phase / 0.15)) : 0
            return 0.15 * envelope * Float(sin(2 * Double.pi * 220 * time))
        }
    }

    private func mixed(seconds: Int) -> [Float] {
        zip(pinkNoise(seconds: seconds, rms: 0.01), syllables(seconds: seconds)).map { $0 + $1 }
    }

    private func writeAudio(_ mono16k: [Float], in folder: URL) throws {
        let rate = 48_000.0
        let frames = AVAudioFrameCount(mono16k.count * 3)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let data = buffer.floatChannelData!
        for index in 0..<Int(frames) {
            data[0][index] = mono16k[index / 3]
            data[1][index] = 0
        }
        let wav = root.appendingPathComponent("fixture-\(UUID().uuidString).wav")
        do {
            let file = try AVAudioFile(forWriting: wav, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
        }
        _ = try M4AFileConverter().convert(from: wav, to: RecordingFolder.audioURL(in: folder))
        try? FileManager.default.removeItem(at: wav)
    }

    private func makeFolder(duration: Double, status: RecordingStatus = .transcribing) throws -> URL {
        let folder = try RecordingFolder.create(root: root, date: t0, timeZone: TimeZone(identifier: "UTC")!)
        try RecordingFolder.write(
            RecordingMeta(startedAt: t0, durationSeconds: duration, devices: .init(mic: "mic", system: nil), status: status, sources: .mic),
            in: folder
        )
        return folder
    }

    private func live(_ audio: [Float], recognizer: SpeechRecognizer, folder: URL) async -> MeetingTranscriptDocument? {
        let store = MeetingTranscriptStore(startedAt: t0, engine: recognizer.engineName, folder: folder)
        let transcriber = LiveTranscriber(recognizer: recognizer, store: store, channels: [.mic], onUpdate: { _ in })
        var index = 0
        while index < audio.count {
            transcriber.push16k(Array(audio[index..<min(index + 1_600, audio.count)]), channel: .mic)
            index += 1_600
        }
        _ = await transcriber.finish()
        return try? MeetingTranscriptFile.read(in: folder, live: true)
    }

    func testSegmenterReportsTheNoiseRunAsARangeAndKeepsItsStart() {
        var segmenter = SpeechSegmenter()
        let tone = (0..<(16_000 * 100)).map { 0.3 * sin(Float($0) * 0.05) }
        let events = segmenter.append(tone) + segmenter.flush()
        let ranges = events.compactMap { event -> (Int, Int)? in
            if case .noise(let start, let end) = event { return (start, end) }
            return nil
        }
        XCTAssertEqual(ranges.count, 1)
        XCTAssertGreaterThan(ranges[0].0, 36 * 16_000)
        XCTAssertLessThan(ranges[0].0, 41 * 16_000)
        XCTAssertEqual(ranges[0].1, tone.count)
    }

    func testANoiseRunEndsAtTheNextQuietCutSoTheSpeechAfterItIsTranscribedLive() {
        var segmenter = SpeechSegmenter()
        var audio = (0..<(16_000 * 85)).map { 0.3 * sin(Float($0) * 0.05) }
        for second in stride(from: 58.0, to: 84.0, by: 1.2) {
            for index in Int(second * 16_000)..<(Int(second * 16_000) + 1_000) { audio[index] = 0 }
        }
        let events = segmenter.append(audio) + segmenter.flush()
        let noise = events.filter { if case .noise = $0 { return true } else { return false } }
        XCTAssertEqual(noise.count, 1)
        if case .noise(let start, let end) = noise[0] {
            XCTAssertEqual(Double(start) / 16_000, 38, accuracy: 3)
            XCTAssertEqual(Double(end) / 16_000, 57, accuracy: 3)
        }
        let live = events.compactMap { event -> Int? in
            if case .segment(let start, _) = event { return start }
            return nil
        }
        XCTAssertEqual(live.count, 4)
        XCTAssertEqual(Double(live[2]) / 16_000, 57, accuracy: 3)
    }

    func testLiveFileKeepsTheNoiseRangesAndTheFinalPassTranscribesThemWithoutDroppingSpeech() async throws {
        let audio = mixed(seconds: 60)
        let folder = try makeFolder(duration: 60)
        try writeAudio(audio, in: folder)
        let liveRecognizer = CountingRecognizer(invents: true)
        let document = await live(audio, recognizer: liveRecognizer, folder: folder)
        let ranges = try XCTUnwrap(document?.noiseRanges)
        XCTAssertFalse(ranges.isEmpty)
        XCTAssertTrue(ranges.allSatisfy { $0.channel == .mic })
        XCTAssertLessThan((document?.segments.map(\.end).max() ?? 99), 45)

        let recognizer = CountingRecognizer(invents: true)
        let pipeline = MeetingPipeline(transcriber: MeetingTranscriber(recognizer: recognizer), notes: NoteStub())
        try await pipeline.process(folder: folder)
        let final = try MeetingTranscriptFile.read(in: folder)
        XCTAssertNil(final.noiseRanges)
        XCTAssertGreaterThan(recognizer.calls.count, 0)
        XCTAssertLessThan(final.segments.map(\.start).min() ?? 99, 1)
        XCTAssertGreaterThan(final.segments.map(\.end).max() ?? 0, 59)
        var covered = 0.0
        var edge = 0.0
        for segment in final.segments.sorted(by: { $0.start < $1.start }) {
            covered += max(0, segment.end - max(segment.start, edge))
            edge = max(edge, segment.end)
        }
        XCTAssertGreaterThan(covered, 58)
    }

    func testPureNoiseRangesAreTriedInTheFinalPassAndNoTextIsInvented() async throws {
        let audio = pinkNoise(seconds: 60, rms: 0.01)
        let folder = try makeFolder(duration: 60)
        try writeAudio(audio, in: folder)
        let recognizer = CountingRecognizer(invents: false)
        let transcriber = MeetingTranscriber(recognizer: recognizer)
        let document = try await transcriber.transcribe(folder: folder, startedAt: t0, sources: .mic, duration: 60)
        XCTAssertEqual(document.segments, [])
        XCTAssertGreaterThan(recognizer.calls.reduce(0, +), 56 * 16_000)
    }

    func testTranscribeRangesOnlyReadsTheRequestedRangesAndOffsetsTheirTimes() async throws {
        let audio = mixed(seconds: 30)
        let folder = try makeFolder(duration: 30)
        try writeAudio(audio, in: folder)
        let recognizer = CountingRecognizer(invents: true)
        let found = try await MeetingTranscriber(recognizer: recognizer).transcribeRanges(
            folder: folder, ranges: [NoiseRange(channel: .mic, start: 10, end: 16)]
        )
        XCTAssertEqual(recognizer.calls.count, 1)
        XCTAssertEqual(Double(recognizer.calls[0]) / 16_000, 6, accuracy: 0.2)
        XCTAssertEqual(found.first?.start ?? 0, 10, accuracy: 0.2)
        XCTAssertEqual(found.first?.end ?? 0, 16, accuracy: 0.2)
    }

    func testNoiseRangesSurviveInTheLiveFileJSON() throws {
        var document = MeetingTranscriptDocument(startedAt: t0, durationSeconds: 5, engine: "x", segments: [])
        document.noiseRanges = [NoiseRange(channel: .system, start: 1.5, end: 9)]
        let folder = try makeFolder(duration: 5)
        try MeetingTranscriptFile.write(document, in: folder, live: true)
        let raw = try String(contentsOf: MeetingTranscriptFile.url(in: folder, live: true), encoding: .utf8)
        XCTAssertTrue(raw.contains("\"noise_ranges\""))
        XCTAssertEqual(try MeetingTranscriptFile.read(in: folder, live: true), document)
    }
}

private struct NoteStub: MeetingNoteWriter {
    func writeNote(folder: URL) async throws -> NoteOutcome {
        try Data("# Nota\n".utf8).write(to: RecordingFolder.noteURL(in: folder))
        return NoteOutcome(generated: true, title: "Nota")
    }
}
