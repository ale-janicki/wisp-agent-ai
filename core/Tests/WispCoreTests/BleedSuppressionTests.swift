import XCTest
@testable import WispCore

/// Answers every segment with one span, so the test sees which mic segments reached the recognizer.
private final class EchoRecognizer: SpeechRecognizer, @unchecked Sendable {
    let engineName = "echo-asr"

    func transcribe(_ samples: [Float], language: String?) async throws -> [RecognizedSpan] {
        [RecognizedSpan(text: "fala", start: 0, end: Double(samples.count) / Double(SpeechAudio.sampleRate))]
    }
}

final class BleedSuppressionTests: XCTestCase {
    private let rate = SpeechAudio.sampleRate
    private let config = BleedConfig.default

    /// Deterministic noise gated by on/off bursts in milliseconds, so the envelope looks like syllables.
    private func speech(pattern: [Int], amplitude: Float, seed: UInt32) -> [Float] {
        var state = seed
        var out: [Float] = []
        for (index, millis) in pattern.enumerated() {
            let count = millis * rate / 1000
            for _ in 0..<count {
                state = state &* 1_664_525 &+ 1_013_904_223
                let noise = Float(Int32(bitPattern: state)) / Float(Int32.max)
                out.append(index % 2 == 0 ? noise * amplitude : 0)
            }
        }
        return out
    }

    private func delayed(_ samples: [Float], milliseconds: Int, gain: Float) -> [Float] {
        let shift = milliseconds * rate / 1000
        return [Float](repeating: 0, count: shift) + samples.prefix(samples.count - shift).map { $0 * gain }
    }

    private let systemPattern = [300, 120, 450, 200, 250, 150, 500, 100, 350, 180, 220, 90]
    private let micPattern = [120, 300, 200, 160, 520, 140, 180, 260, 300, 120, 400, 200]

    private func window(_ system: [Float]) -> [Float] {
        let pad = [Float](repeating: 0, count: config.padSamples)
        return pad + system + pad
    }

    func testPureBleedIsDropped() {
        let system = speech(pattern: systemPattern, amplitude: 0.2, seed: 1)
        let mic = delayed(system, milliseconds: 0, gain: 0.25)
        XCTAssertTrue(BleedDetector.isBleed(mic: mic, systemWindow: window(system), config: config))
    }

    func testBleedWithinLagWindowIsDropped() {
        let system = speech(pattern: systemPattern, amplitude: 0.2, seed: 2)
        for milliseconds in [60, 140] {
            let mic = delayed(system, milliseconds: milliseconds, gain: 0.25)
            XCTAssertTrue(BleedDetector.isBleed(mic: mic, systemWindow: window(system), config: config), "\(milliseconds) ms")
        }
    }

    func testDoubleTalkWithLouderMicIsKept() {
        let system = speech(pattern: systemPattern, amplitude: 0.1, seed: 3)
        let mic = zip(speech(pattern: micPattern, amplitude: 0.4, seed: 4), delayed(system, milliseconds: 40, gain: 0.25))
            .map { $0 + $1 }
        XCTAssertFalse(BleedDetector.isBleed(mic: mic, systemWindow: window(system), config: config))
    }

    func testIndependentSpeechIsKeptEvenWhenQuieter() {
        let system = speech(pattern: systemPattern, amplitude: 0.3, seed: 5)
        let mic = speech(pattern: micPattern, amplitude: 0.1, seed: 6)
        XCTAssertFalse(BleedDetector.isBleed(mic: mic, systemWindow: window(system), config: config))
    }

    func testMicSpeechAloneIsKept() {
        let mic = speech(pattern: micPattern, amplitude: 0.2, seed: 7)
        let silence = [Float](repeating: 0, count: mic.count)
        XCTAssertFalse(BleedDetector.isBleed(mic: mic, systemWindow: window(silence), config: config))
    }

    func testHistoryWindowAndUnknownRangeKeepsSegment() {
        var history = ChannelHistory(capacity: 10 * rate)
        let system = speech(pattern: systemPattern, amplitude: 0.2, seed: 8)
        let start = 3 * rate
        history.append([Float](repeating: 0, count: start))
        history.append(system)
        let mic = delayed(system, milliseconds: 80, gain: 0.25)
        XCTAssertTrue(BleedDetector.isBleed(mic: mic, micStart: start, system: history, config: config))
        XCTAssertFalse(BleedDetector.isBleed(mic: mic, micStart: start - rate, system: history, config: config))
    }

    func testHistoryDropsOldestPastCapacity() {
        var history = ChannelHistory(capacity: 100)
        history.append([Float](repeating: 1, count: 250))
        XCTAssertEqual(history.end, 250)
        XCTAssertNil(history.window(from: 100, to: 120))
        XCTAssertEqual(history.window(from: 200, to: 260)?.reduce(0, +), 50)
    }

    // MARK: short segments

    func testShortQuietIndependentInterjectionIsKept() {
        let system = speech(pattern: systemPattern, amplitude: 0.3, seed: 9)
        for trial in 0..<40 {
            // A 0.4 s "sim" said over the other person's speech, quieter than the speakers.
            let mic = speech(pattern: [60, 120, 40, 140, 40], amplitude: 0.05, seed: UInt32(100 + trial))
            XCTAssertEqual(mic.count, 2 * rate / 5)
            let offset = (trial * 997) % (system.count - mic.count)
            let slice = Array(system[offset..<(offset + mic.count)])
            XCTAssertFalse(BleedDetector.isBleed(mic: mic, systemWindow: window(slice), config: config), "trial \(trial)")
        }
    }

    func testOneAndAHalfSecondDelayedCopyIsDropped() {
        let system = speech(pattern: [180, 90, 260, 120, 200, 80, 300, 70, 200], amplitude: 0.2, seed: 10)
        XCTAssertEqual(system.count, 3 * rate / 2)
        let mic = delayed(system, milliseconds: 50, gain: 0.25)
        XCTAssertLessThan(mic.count / config.frameSamples, config.shortSegmentFrames)
        XCTAssertTrue(BleedDetector.isBleed(mic: mic, systemWindow: window(system), config: config))
    }

    func testSegmentsUnderOneSecondAreNeverJudgedAndUnderTwoNeedTheStricterCorrelation() {
        XCTAssertEqual(config.minFrames * config.frameSamples, rate)
        XCTAssertEqual(config.shortSegmentFrames * config.frameSamples, 2 * rate)
        XCTAssertEqual(config.requiredCorrelation(frames: 60), 0.85)
        XCTAssertEqual(config.requiredCorrelation(frames: 80), 0.7)
        let system = speech(pattern: [200, 100, 300, 100, 200], amplitude: 0.2, seed: 11)
        XCTAssertLessThan(system.count, rate)
        XCTAssertFalse(BleedDetector.isBleed(mic: system.map { $0 * 0.25 }, systemWindow: window(system), config: config))
    }

    // MARK: ring history

    func testHistoryRingWrapsAndReturnsTheExactWindow() {
        var history = ChannelHistory(capacity: 100)
        var next: Float = 0
        for size in [37, 37, 37, 250, 1, 64] {
            history.append((0..<size).map { _ in
                next += 1
                return next
            })
        }
        XCTAssertEqual(history.end, 426)
        XCTAssertNil(history.window(from: 300, to: 340))
        XCTAssertEqual(history.window(from: 330, to: 426), (331...426).map(Float.init))
        XCTAssertEqual(history.window(from: 420, to: 430), (421...426).map(Float.init) + [0, 0, 0, 0])
    }

    func testSkipRefusesWhatCameBeforeAndKeepsTheIndexGoing() {
        var history = ChannelHistory(capacity: 100)
        history.append([Float](repeating: 1, count: 30))
        history.skip(50)
        XCTAssertEqual(history.end, 80)
        XCTAssertNil(history.window(from: 20, to: 90))
        history.append([Float](repeating: 2, count: 10))
        XCTAssertEqual(history.window(from: 80, to: 92), [Float](repeating: 2, count: 10) + [0, 0])
    }

    // MARK: alignment in the live transcriber

    private func mine(_ segments: [MeetingSegment]) -> [MeetingSegment] { segments.filter { $0.speaker == "eu" } }

    private func silence(seconds: Double) -> [Float] { [Float](repeating: 0, count: Int(seconds * Double(rate))) }

    /// The system tap started 5 s after the mic. The mic's first 3 s look like a copy of what the speakers play later, so
    /// a history that ignored the offset would drop them; the history cannot cover them, so they are kept. The real
    /// echo, once both channels run (and its window lies inside the system history), is still dropped.
    func testLateSystemStartNeverDropsTheMicAndStillDropsTheRealEcho() async {
        let other = speech(pattern: systemPattern, amplitude: 0.3, seed: 12)
        let live = LiveTranscriber(
            recognizer: EchoRecognizer(), store: MeetingTranscriptStore(startedAt: Date(), engine: "x"), onUpdate: { _ in }
        )
        live.skipGap(seconds: 5, channel: .system)
        live.push16k(silence(seconds: 1) + other + silence(seconds: 4), channel: .system)
        let echo = delayed(other, milliseconds: 50, gain: 0.25)
        live.push16k(other.map { $0 * 0.25 } + silence(seconds: 5 - Double(other.count) / Double(rate)), channel: .mic)
        live.push16k(silence(seconds: 1) + echo + silence(seconds: 4), channel: .mic)
        let result = mine(await live.finish())
        XCTAssertEqual(result.count, 1, "\(result)")
        XCTAssertLessThan(result.first?.start ?? 99, 1)
    }

    /// A gap on the mic only: its next speech lines up with system silence, not with the system speech the same number of
    /// samples earlier, so it is kept.
    func testGapOnTheMicOnlyKeepsTheMicAlignedWithTheSystem() async {
        let other = speech(pattern: systemPattern, amplitude: 0.3, seed: 13)
        let live = LiveTranscriber(
            recognizer: EchoRecognizer(), store: MeetingTranscriptStore(startedAt: Date(), engine: "x"), onUpdate: { _ in }
        )
        live.push16k(other + silence(seconds: 12), channel: .system)
        live.push16k(silence(seconds: 1), channel: .mic)
        live.skipGap(seconds: 5, channel: .mic)
        live.push16k(delayed(other, milliseconds: 50, gain: 0.25) + silence(seconds: 3), channel: .mic)
        let result = mine(await live.finish())
        XCTAssertEqual(result.count, 1, "\(result)")
        XCTAssertGreaterThan(result.first?.start ?? 0, 5)
    }
}
