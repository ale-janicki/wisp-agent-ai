import XCTest
@testable import WispCore

final class RecordingPauseTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testGatePassesBeforeDropsDuringAndShiftsAfterAPause() {
        var gate = CaptureGate()
        XCTAssertEqual(gate.admit(5), 5)
        gate.pause(at: 10)
        XCTAssertTrue(gate.isPaused)
        XCTAssertNil(gate.admit(10))
        XCTAssertNil(gate.admit(500))
        XCTAssertEqual(gate.admit(9.99), 9.99, "a buffer stamped before the pause is still kept when it is read late")
        gate.resume(at: 40)
        XCTAssertFalse(gate.isPaused)
        XCTAssertNil(gate.admit(39.9))
        XCTAssertEqual(gate.admit(40) ?? -1, 10, accuracy: 1e-9)
        XCTAssertEqual(gate.admit(45) ?? -1, 15, accuracy: 1e-9)
    }

    func testGateAccumulatesSeveralPausesAndIgnoresRepeats() {
        var gate = CaptureGate()
        gate.resume(at: 1)
        gate.pause(at: 10)
        gate.pause(at: 12)
        gate.resume(at: 20)
        gate.resume(at: 25)
        gate.pause(at: 30)
        gate.resume(at: 50)
        XCTAssertEqual(gate.admit(15) == nil, true)
        XCTAssertEqual(gate.admit(25) ?? -1, 15, accuracy: 1e-9)
        XCTAssertNil(gate.admit(35))
        XCTAssertEqual(gate.admit(60) ?? -1, 30, accuracy: 1e-9)
    }

    func testTimelineStaysContinuousForTheLiveTranscriberAcrossAPause() {
        var gate = CaptureGate()
        let aligner = LiveAudioAligner()
        let chunk = [Float](repeating: 0.3, count: 4_800)
        XCTAssertNil(aligner.align(chunk, channel: .mic, at: gate.admit(100)!).gapSeconds)
        gate.pause(at: 100.1)
        gate.resume(at: 700.1)
        let joined = aligner.align(chunk, channel: .mic, at: gate.admit(700.1)!)
        XCTAssertNil(joined.gapSeconds)
        XCTAssertEqual(joined.samples.count, chunk.count, "no silence is inserted for the paused span")
        let raw = LiveAudioAligner()
        _ = raw.align(chunk, channel: .mic, at: 100)
        XCTAssertNotNil(raw.align(chunk, channel: .mic, at: 700.1).gapSeconds, "without the gate the same span would skip 10 minutes")
    }

    func testElapsedClockAndLimitDoNotAdvanceWhilePaused() {
        var clock = RecordingLimitClock(limit: 600)
        clock.start(at: 1_000)
        clock.pause(at: 1_100)
        XCTAssertEqual(clock.active(at: 1_100), 100, accuracy: 1e-9)
        XCTAssertEqual(clock.active(at: 9_000), 100, accuracy: 1e-9)
        XCTAssertNil(clock.tick(at: 9_000))
        XCTAssertEqual(clock.remaining(at: 9_000), 500, accuracy: 1e-9)
        clock.resume(at: 9_000)
        XCTAssertEqual(clock.active(at: 9_060), 160, accuracy: 1e-9)
        XCTAssertEqual(clock.tick(at: 9_300), .warning(remaining: 200))
        XCTAssertEqual(clock.tick(at: 9_500), .reached)
    }

    func testRecordControlOffersPauseOnlyWhileRecording() {
        let running = RecordControl(phase: .recording, elapsed: 65, canRecord: true)
        XCTAssertEqual(running.title, "Parar")
        XCTAssertEqual(running.pauseTitle, "Pausar")
        XCTAssertFalse(running.isPaused)
        let paused = RecordControl(phase: .recording, elapsed: 65, canRecord: true, isPaused: true)
        XCTAssertEqual(paused.title, "Parar")
        XCTAssertTrue(paused.isEnabled)
        XCTAssertEqual(paused.pauseTitle, "Retomar")
        XCTAssertEqual(paused.timer, "1:05")
        XCTAssertNil(RecordControl(phase: .idle, elapsed: 0, canRecord: true, isPaused: true).pauseTitle)
        XCTAssertFalse(RecordControl(phase: .finishing, elapsed: 0, canRecord: true, isPaused: true).isPaused)
    }

    func testPauseLabelCarriesTheWallClockTimesAndMetaRoundTrips() throws {
        let pause = RecordingPause(startedAt: t0, endedAt: t0.addingTimeInterval(600), position: 61)
        XCTAssertEqual(pause.label(timeZone: utc), "Pausado 08:00–08:10")
        XCTAssertEqual(RecordingPause(startedAt: t0, position: 3).label(timeZone: utc), "Pausado desde 08:00")
        var meta = RecordingMeta(startedAt: t0, devices: .init(mic: nil, system: nil))
        meta.pauses = [pause]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(meta)
        let raw = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(raw.contains("\"at_s\""))
        XCTAssertTrue(raw.contains("\"ended_at\""))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(RecordingMeta.self, from: data).pauses, [pause])
        XCTAssertNil(RecordingMeta(startedAt: t0, devices: .init(mic: nil, system: nil)).pauses)
    }

    func testTheTranscriptShowsAPauseMarkerBetweenTheLinesAroundIt() {
        let segments = [
            MeetingSegment(start: 0, end: 4, speaker: "eu", text: "antes"),
            MeetingSegment(start: 61, end: 65, speaker: "outros", text: "depois"),
        ]
        let pause = RecordingPause(startedAt: t0, endedAt: t0.addingTimeInterval(120), position: 30)
        let lines = MeetingBookmarks.lines(segments: segments, bookmarks: [MeetingBookmark(id: "b", time: 70)], pauses: [pause], timeZone: utc)
        XCTAssertEqual(lines.map(\.text), ["antes", "Pausado 08:00–08:02", "depois", "Momento marcado"])
        XCTAssertEqual(lines.map(\.isPause), [false, true, false, false])
        XCTAssertEqual(lines[1].time, "0:30")
    }
}
