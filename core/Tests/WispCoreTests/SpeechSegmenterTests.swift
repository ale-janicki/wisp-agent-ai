import XCTest
@testable import WispCore

private final class CountingRecognizer: SpeechRecognizer, @unchecked Sendable {
    let engineName = "counting"
    private let lock = NSLock()
    private var sizes: [Int] = []

    var calls: [Int] { lock.withLock { sizes } }

    func transcribe(_ samples: [Float], language: String?) async throws -> [RecognizedSpan] {
        let number = lock.withLock { () -> Int in
            sizes.append(samples.count)
            return sizes.count
        }
        return [RecognizedSpan(text: "fala\(number)", start: 0, end: Double(samples.count) / 16_000)]
    }
}

final class SpeechSegmenterTests: XCTestCase {
    private let frame = 480
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func quiet(_ frames: Int) -> [Float] { [Float](repeating: 0, count: frames * frame) }

    private func voiced(_ frames: Int) -> [Float] { (0..<(frames * frame)).map { 0.3 * sin(Float($0) * 0.05) } }

    private func speechLike(_ frames: Int) -> [Float] {
        var audio = voiced(frames)
        for index in stride(from: 44, to: frames, by: 45) {
            for sample in (index * frame)..<((index + 1) * frame) { audio[sample] = 0 }
        }
        return audio
    }

    private func square(_ frames: Int, level: Float) -> [Float] { (0..<(frames * frame)).map { $0 % 2 == 0 ? level : -level } }

    private func run(_ audio: [Float], chunk: Int? = nil) -> [SegmenterEvent] {
        var segmenter = SpeechSegmenter()
        var events: [SegmenterEvent] = []
        if let chunk {
            var index = 0
            while index < audio.count {
                events += segmenter.append(Array(audio[index..<min(index + chunk, audio.count)]))
                index += chunk
            }
        } else {
            events += segmenter.append(audio)
        }
        return events + segmenter.flush()
    }

    private func segments(_ events: [SegmenterEvent]) -> [(start: Int, count: Int)] {
        events.compactMap { event in
            if case .segment(let start, let samples) = event { return (start, samples.count) }
            return nil
        }
    }

    func testSegmentBoundariesFollowPadsAndRedemptionExactly() {
        let audio = quiet(40) + voiced(100) + quiet(100)
        let events = run(audio)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first, .opened(startSample: 19_200 - 4_800))
        let found = segments(events)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].start, 14_400)
        XCTAssertEqual(found[0].count, 67_200 - 14_400 + 6_400)
    }

    func testResultIsIdenticalWhateverTheChunkSizeOfTheInput() {
        let audio = quiet(40) + voiced(100) + quiet(40) + voiced(60) + quiet(100)
        XCTAssertEqual(run(audio), run(audio, chunk: 997))
        XCTAssertEqual(run(audio), run(audio, chunk: 160))
    }

    func testPauseShorterThanRedemptionStaysOneSegmentAndLongerSplits() {
        let short = segments(run(voiced(40) + quiet(15) + voiced(40) + quiet(100)))
        XCTAssertEqual(short.count, 1)
        let long = segments(run(voiced(40) + quiet(25) + voiced(40) + quiet(100)))
        XCTAssertEqual(long.count, 2)
    }

    func testSecondSegmentPrePadNeverOverlapsTheFirstSegmentTail() {
        let found = segments(run(voiced(40) + quiet(20) + voiced(40) + quiet(100)))
        XCTAssertEqual(found.count, 2)
        XCTAssertEqual(found[1].start, found[0].start + found[0].count)
    }

    func testSpeechShorterThanTheMinimumIsDroppedWithoutAnyEvent() {
        XCTAssertEqual(run(quiet(10) + voiced(3) + quiet(100)), [])
        XCTAssertEqual(segments(run(quiet(10) + voiced(10) + quiet(100))).count, 1)
    }

    func testAShortWordLikeSimOrNaoBecomesASegment() {
        let found = segments(run(quiet(30) + voiced(5) + quiet(100)))
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found[0].count, 4_800 + 5 * frame + 6_400)
    }

    func testHysteresisKeepsASegmentOpenBelowTheOnThresholdButNeverStartsOne() {
        XCTAssertEqual(run(square(100, level: 0.0025)), [])
        let held = segments(run(voiced(20) + square(60, level: 0.0025) + voiced(20) + quiet(100)))
        XCTAssertEqual(held.count, 1)
        let dropped = segments(run(voiced(20) + square(60, level: 0.0015) + voiced(20) + quiet(100)))
        XCTAssertEqual(dropped.count, 2)
    }

    func testBackgroundNoiseOpensNothingAndCostsNoInference() {
        XCTAssertEqual(run(square(600 * 33, level: 0.0005)), [])
    }

    func testContinuousSpeechIsCutAtTwentySecondsOnTheQuietestFrameOfTheLastTwoSeconds() {
        var audio = voiced(833)
        for index in (633 * frame)..<(634 * frame) { audio[index] = 0 }
        let events = run(audio)
        XCTAssertEqual(events.map { event -> String in
            switch event {
            case .opened: "opened"
            case .segment: "segment"
            case .dropped: "dropped"
            case .noise: "noise"
            }
        }, ["opened", "segment", "opened", "segment"])
        let found = segments(events)
        XCTAssertEqual(found[0].start, 0)
        XCTAssertEqual(found[0].count, 633 * frame + frame / 2)
        XCTAssertLessThanOrEqual(found[0].count, 20 * 16_000)
        XCTAssertEqual(found[1].start, found[0].count)
        XCTAssertEqual(found[1].start + found[1].count, 833 * frame)
    }

    func testEverySegmentOfLongSpeechIsAtMostTwentySeconds() {
        let found = segments(run(speechLike(1_500)))
        XCTAssertEqual(found.count, 3)
        XCTAssertTrue(found.allSatisfy { $0.count <= 20 * 16_000 })
        XCTAssertEqual(found.map(\.count).reduce(0, +), 1_500 * frame)
    }

    func testForcedCutWithoutAQuietFrameOverlapsHalfASecondForTheTextDedupe() {
        let found = segments(run(voiced(1_500)))
        XCTAssertEqual(found.count, 3)
        XCTAssertEqual(found[1].start, found[0].start + found[0].count - 8_000)
        XCTAssertEqual(found[2].start, found[1].start + found[1].count - 8_000)
    }

    func testForcedCutOnAQuietFrameDoesNotOverlap() {
        let found = segments(run(speechLike(1_500)))
        XCTAssertEqual(found[1].start, found[0].start + found[0].count)
    }

    func testAfterTwoNoisyCutsTheRestOfTheRunIsNoiseAndNeverSent() {
        let events = run(voiced(3_333))
        XCTAssertEqual(segments(events).count, 2)
        XCTAssertGreaterThanOrEqual(events.filter { $0 == .dropped }.count, 2)
    }

    func testContinuousNoiseAboveTheOffLevelEndsAsNoiseAndRaisesTheThreshold() {
        let events = run(square(3_333, level: 0.0035) + voiced(40) + quiet(100))
        XCTAssertEqual(segments(events).count, 3)
        let later = segments(run(square(3_333, level: 0.0035) + square(1_000, level: 0.0035) + voiced(40) + quiet(100)))
        XCTAssertEqual(later.count, 3)
    }

    func testAmbientNoiseRaisesTheOnLevelSoQuietBlipsInsideItDoNotOpenSegments() {
        let burst = square(20, level: 0.004)
        XCTAssertEqual(segments(run(quiet(167) + burst + quiet(100))).count, 1)
        XCTAssertEqual(segments(run(square(167, level: 0.002) + burst + quiet(100))).count, 0)
        XCTAssertEqual(segments(run(square(167, level: 0.002) + voiced(20) + quiet(100))).count, 1)
    }

    func testSensitiveConfigOpensOnVeryQuietSpeech() {
        var segmenter = SpeechSegmenter(config: .sensitive)
        let events = segmenter.append(quiet(30) + square(30, level: 0.002) + quiet(100)) + segmenter.flush()
        XCTAssertEqual(segments(events).count, 1)
        XCTAssertEqual(segments(run(quiet(30) + square(30, level: 0.002) + quiet(100))).count, 0)
    }

    func testOverlappedForcedCutsDoNotRepeatWordsInTheTranscript() async {
        final class Script: SpeechRecognizer, @unchecked Sendable {
            let engineName = "script"
            private let lock = NSLock()
            private var calls = 0

            func transcribe(_ samples: [Float], language: String?) async throws -> [RecognizedSpan] {
                let number = lock.withLock { () -> Int in
                    calls += 1
                    return calls
                }
                let text = number == 1 ? "um dois tres quatro cinco" : "quatro cinco seis sete"
                return [RecognizedSpan(text: text, start: 0, end: Double(samples.count) / 16_000)]
            }
        }
        let store = MeetingTranscriptStore(startedAt: t0, engine: "script")
        let live = LiveTranscriber(recognizer: Script(), store: store, onUpdate: { _ in })
        for _ in 0..<30 { live.push16k(voiced(33), channel: .mic) }
        let result = await live.finish()
        XCTAssertEqual(result.map(\.text), ["um dois tres quatro cinco", "seis sete"])
    }

    func testSkipGapFlushesTheOpenSegmentAndMovesTheTimeline() {
        var segmenter = SpeechSegmenter()
        _ = segmenter.append(voiced(40))
        let flushed = segmenter.skipGap(samples: 16_000 * 60)
        XCTAssertEqual(segments(flushed).count, 1)
        XCTAssertEqual(segmenter.totalSamples, 40 * frame + 16_000 * 60)
        let next = segmenter.append(voiced(40) + quiet(100))
        XCTAssertEqual(segments(next).first?.start, 40 * frame + 16_000 * 60)
    }

    func testLiveTranscriberCallsTheRecognizerExactlyOncePerSegment() async {
        let recognizer = CountingRecognizer()
        let store = MeetingTranscriptStore(startedAt: t0, engine: "counting")
        let updates = UpdateCounter()
        let live = LiveTranscriber(recognizer: recognizer, store: store, onUpdate: { _ in updates.bump() })
        for _ in 0..<3 {
            live.push16k(voiced(100), channel: .mic)
            live.push16k(quiet(100), channel: .mic)
        }
        live.push16k(voiced(100), channel: .system)
        live.push16k(quiet(100), channel: .system)
        live.push16k(quiet(2_000), channel: .system)
        let result = await live.finish()
        XCTAssertEqual(recognizer.calls.count, 4)
        XCTAssertEqual(result.filter { $0.speaker == "eu" }.count, 3)
        XCTAssertEqual(result.filter { $0.speaker == "outros" }.count, 1)
        XCTAssertTrue(result.allSatisfy { $0.isFinal })
        XCTAssertGreaterThan(updates.count, 4)
    }

    func testSilentChannelNeverReachesTheRecognizer() async {
        let recognizer = CountingRecognizer()
        let live = LiveTranscriber(recognizer: recognizer, store: MeetingTranscriptStore(startedAt: t0, engine: "x"), onUpdate: { _ in })
        for _ in 0..<60 {
            live.push16k(quiet(33), channel: .mic)
            live.push16k(square(33, level: 0.0004), channel: .system)
        }
        let result = await live.finish()
        XCTAssertEqual(recognizer.calls, [])
        XCTAssertEqual(result, [])
    }

    func testTypingMarkAppearsWhileASegmentIsOpenAndIsReplacedByTheFinalLine() async {
        let recognizer = CountingRecognizer()
        let store = MeetingTranscriptStore(startedAt: t0, engine: "x")
        let live = LiveTranscriber(recognizer: recognizer, store: store, onUpdate: { _ in })
        live.push16k(voiced(60), channel: .mic)
        var sawTyping = false
        for _ in 0..<50 where !sawTyping {
            try? await Task.sleep(for: .milliseconds(20))
            sawTyping = store.snapshot.contains { !$0.isFinal && $0.text == "…" }
        }
        XCTAssertTrue(sawTyping)
        XCTAssertEqual(recognizer.calls, [])
        live.push16k(quiet(100), channel: .mic)
        let result = await live.finish()
        XCTAssertEqual(result.map(\.text), ["fala1"])
    }
}

private final class UpdateCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func bump() { lock.withLock { value += 1 } }
}
