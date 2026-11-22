import AVFoundation
import XCTest
@testable import WispCore

private final class FakeSource: AudioSource, @unchecked Sendable {
    let deviceName: String?
    var failOnStart: String?
    private(set) var started = 0
    private(set) var stopped = 0
    private var ring: CaptureRing?
    private var cursor = 0.0

    init(name: String) { deviceName = name }

    func start(ring: CaptureRing) throws {
        if let failOnStart { throw MeetingRecorderError.source(failOnStart) }
        started += 1
        self.ring = ring
    }

    func stop() {
        stopped += 1
        ring = nil
    }

    func emit(_ samples: [Float]) {
        ring?.push(mono: samples, time: cursor)
        cursor += Double(samples.count) / Double(CaptureFormat.sampleRate)
    }

    func skip(seconds: Double) { cursor += seconds }
}

private final class FakeConverter: AudioFileConverter, @unchecked Sendable {
    private(set) var calls: [(URL, URL)] = []
    var failure: String?

    func convert(from source: URL, to destination: URL) throws -> Double {
        calls.append((source, destination))
        if let failure { throw MeetingRecorderError.sink(failure) }
        try Data("m4a".utf8).write(to: destination)
        return 3
    }
}

private final class ClockBox: @unchecked Sendable {
    var now = 0.0
}

private final class MemorySink: AudioFileSink, @unchecked Sendable {
    private(set) var frames: [Float] = []
    private(set) var finished = false
    var failWrites = false

    func write(_ frames: [Float]) throws {
        if failWrites { throw MeetingRecorderError.sink("disco cheio") }
        self.frames.append(contentsOf: frames)
    }

    func finish() throws { finished = true }
}

private struct FixedDisk: DiskSpace {
    var bytes: Int64?
    func availableBytes(at url: URL) -> Int64? { bytes }
}

final class MeetingCaptureTests: XCTestCase {
    private var root: URL!
    private let utc = TimeZone(identifier: "UTC")!
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("wisp-rec-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func recorder(
        mic: FakeSource = FakeSource(name: "MacBook Pro Microphone"), system: FakeSource = FakeSource(name: "Saída do sistema"),
        sink: MemorySink = MemorySink(), converter: FakeConverter = FakeConverter(), clock: ClockBox = ClockBox(),
        disk: Int64? = 50_000_000_000, unsupported: String? = nil
    ) -> MeetingRecorder {
        let base = root!
        return MeetingRecorder(
            mic: mic, system: system, root: { base }, makeSink: { _ in sink }, converter: converter,
            diskSpace: FixedDisk(bytes: disk), unsupportedMessage: { unsupported }, clock: { clock.now },
            autoPump: false, timeZone: utc
        )
    }

    func testFolderNameIsTimestampInGivenZone() {
        XCTAssertEqual(RecordingFolder.name(for: t0, timeZone: utc), "2027-01-15_08-00-00")
    }

    func testDefaultRootIsWispReunioesAndConfiguredPathWins() {
        let home = URL(fileURLWithPath: "/Users/x")
        XCTAssertEqual(RecordingFolder.root(configured: nil, environment: [:], home: home).path, "/Users/x/Wisp/reunioes")
        XCTAssertEqual(RecordingFolder.root(configured: "  ", environment: [:], home: home).path, "/Users/x/Wisp/reunioes")
        XCTAssertEqual(RecordingFolder.root(configured: "~/Gravacoes", home: home).path, "/Users/x/Gravacoes")
        XCTAssertEqual(RecordingFolder.root(configured: "/Volumes/hd/rec", home: home).path, "/Volumes/hd/rec")
    }

    func testSameSecondFolderGetsSuffixInsteadOfOverwriting() throws {
        let first = try RecordingFolder.create(root: root, date: t0, timeZone: utc)
        let second = try RecordingFolder.create(root: root, date: t0, timeZone: utc)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.lastPathComponent, "2027-01-15_08-00-00-2")
    }

    func testMetaRoundTripUsesSpecKeys() throws {
        let folder = try RecordingFolder.create(root: root, date: t0, timeZone: utc)
        let meta = RecordingMeta(startedAt: t0, durationSeconds: 12.5, devices: .init(mic: "m", system: "s"), detectedApp: "us.zoom.xos", status: .transcribing)
        try RecordingFolder.write(meta, in: folder)
        let raw = try String(contentsOf: RecordingFolder.metaURL(in: folder), encoding: .utf8)
        XCTAssertTrue(raw.contains("\"started_at\""))
        XCTAssertTrue(raw.contains("\"duration_s\""))
        XCTAssertTrue(raw.contains("\"detected_app\""))
        XCTAssertTrue(raw.contains("\"transcribing\""))
        XCTAssertEqual(try RecordingFolder.read(in: folder), meta)
    }

    func testMixerPutsMicLeftSystemRightAndWaitsForTheSlowerSide() {
        var mixer = StereoMixer(maxSkewFrames: 100, toleranceFrames: 0)
        mixer.push(mic: [1, 2, 3], at: 0)
        XCTAssertEqual(mixer.pull(), [])
        mixer.push(system: [-1, -2], at: 0)
        XCTAssertEqual(mixer.pull(), [1, -1, 2, -2])
        mixer.push(system: [-3], at: 2.0 / 48_000)
        XCTAssertEqual(mixer.pull(), [3, -3])
    }

    func testMixerPadsSilenceWhenOneSideStallsBeyondSkewAndOnFlush() {
        var mixer = StereoMixer(maxSkewFrames: 2, toleranceFrames: 0)
        mixer.push(mic: [1, 2, 3, 4, 5], at: 0)
        XCTAssertEqual(mixer.pull(), [1, 0, 2, 0, 3, 0])
        XCTAssertEqual(mixer.pull(flush: true), [4, 0, 5, 0])
        XCTAssertEqual(mixer.pull(flush: true), [])
    }

    func testMixerAlignsByHostTimeNotArrivalOrder() {
        var mixer = StereoMixer(maxSkewFrames: 100, toleranceFrames: 0)
        let frame = 1.0 / 48_000
        mixer.push(system: [-3, -4], at: 2 * frame)
        mixer.push(mic: [1, 2, 3, 4], at: 0)
        XCTAssertEqual(mixer.pull(), [1, 0, 2, 0, 3, -3, 4, -4])
    }

    func testMixerKeepsTheRealOffsetBetweenSourcesStartingApart() {
        var mixer = StereoMixer(maxSkewFrames: 100, toleranceFrames: 0)
        mixer.push(mic: [1, 1, 1, 1], at: 0)
        mixer.push(system: [-1, -1], at: 2.0 / 48_000)
        XCTAssertEqual(mixer.pull(), [1, 0, 1, 0, 1, -1, 1, -1])
    }

    func testMixerDropsSamplesThatWereAlreadyEmitted() {
        var mixer = StereoMixer(maxSkewFrames: 100, toleranceFrames: 0)
        let frame = 1.0 / 48_000
        mixer.push(mic: [1, 2], at: 0)
        mixer.push(system: [-1, -2], at: 0)
        XCTAssertEqual(mixer.pull(), [1, -1, 2, -2])
        mixer.push(mic: [3], at: 2 * frame)
        mixer.push(system: [-7, -3], at: 1 * frame)
        XCTAssertEqual(mixer.pull(), [3, -3])
    }

    func testMixerStartsAnUnansweredSourceAfterTheSkewBoundAndOnFlush() {
        var mixer = StereoMixer(maxSkewFrames: 2, toleranceFrames: 0)
        mixer.push(mic: [1, 2], at: 5)
        XCTAssertEqual(mixer.pull(), [])
        XCTAssertEqual(mixer.pull(flush: true), [1, 0, 2, 0])
        var long = StereoMixer(maxSkewFrames: 2, toleranceFrames: 0)
        long.push(mic: [1, 2, 3, 4], at: 5)
        XCTAssertEqual(long.pull(), [1, 0, 2, 0])
    }

    func testMixerFillsAGapAndDropsAnOverlapOnceBeyondTolerance() {
        var mixer = StereoMixer(maxSkewFrames: 1000, toleranceFrames: 2)
        let frame = 1.0 / 48_000
        mixer.push(mic: [1, 1], at: 0)
        mixer.push(mic: [2, 2], at: 6 * frame)
        mixer.push(system: [0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5], at: 0)
        XCTAssertEqual(mixer.pull(flush: true).enumerated().filter { $0.offset % 2 == 0 }.map(\.element), [1, 1, 0, 0, 0, 0, 2, 2])
        var overlap = StereoMixer(maxSkewFrames: 1000, toleranceFrames: 1)
        overlap.push(mic: [1, 2, 3, 4], at: 0)
        overlap.push(mic: [9, 9, 5], at: 2 * frame)
        XCTAssertEqual(overlap.pull(flush: true).enumerated().filter { $0.offset % 2 == 0 }.map(\.element), [1, 2, 3, 4, 5])
    }

    func testMixerTrustsArrivalWithinToleranceSoJitterDoesNotInsertSilence() {
        var mixer = StereoMixer(maxSkewFrames: 1000, toleranceFrames: 2)
        let frame = 1.0 / 48_000
        mixer.push(mic: [1, 1, 1], at: 0)
        mixer.push(mic: [2, 2, 2], at: 4 * frame)
        mixer.push(system: [0, 0, 0, 0, 0, 0], at: 0)
        XCTAssertEqual(mixer.pull().count, 12)
    }

    func testRingKeepsOrderSplitsLargePushesAndCountsOverruns() {
        let ring = CaptureRing(slotFrames: 4, slotCount: 3)
        ring.push(mono: [1, 2, 3, 4, 5, 6], time: 10)
        var popped: [([Float], Double, Double)] = []
        while ring.pop({ popped.append((Array($0.samples), $0.rate, $0.time)) }) {}
        XCTAssertEqual(popped.map(\.0), [[1, 2, 3, 4], [5, 6]])
        XCTAssertEqual(popped[1].2, 10 + 4.0 / 48_000, accuracy: 1e-9)
        ring.push(mono: [Float](repeating: 1, count: 16), time: 0)
        XCTAssertEqual(ring.overrunCount, 1)
        var count = 0
        while ring.pop({ _ in count += 1 }) {}
        XCTAssertEqual(count, 3)
    }

    func testRingInterleavesPlanarInputAndKeepsChannels() {
        let ring = CaptureRing(slotFrames: 8, slotCount: 2)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 3)
        let right = UnsafeMutablePointer<Float>.allocate(capacity: 3)
        defer { left.deallocate(); right.deallocate() }
        for index in 0..<3 { left[index] = Float(index); right[index] = Float(-index) }
        var planes = [left, right]
        planes.withUnsafeMutableBufferPointer { ring.push(planar: $0.baseAddress!, channels: 2, frames: 3, rate: 44_100, time: 1) }
        var seen: (samples: [Float], channels: Int, rate: Double)?
        ring.pop { seen = (Array($0.samples), $0.channels, $0.rate) }
        XCTAssertEqual(seen?.samples, [0, 0, 1, -1, 2, -2])
        XCTAssertEqual(seen?.channels, 2)
        XCTAssertEqual(seen?.rate, 44_100)
    }

    func testStallWatchdogFlagsAfterTimeoutWithoutProgressAndRecovers() {
        var watch = StallWatchdog(timeout: 5)
        XCTAssertFalse(watch.observe(totalFrames: 0, now: 0))
        XCTAssertFalse(watch.observe(totalFrames: 0, now: 4.9))
        XCTAssertTrue(watch.observe(totalFrames: 0, now: 5))
        XCTAssertFalse(watch.observe(totalFrames: 10, now: 5.1))
        XCTAssertFalse(watch.observe(totalFrames: 10, now: 10))
        XCTAssertTrue(watch.observe(totalFrames: 10, now: 10.1))
    }

    func testSilenceDetectorFlagsOnceAfterTenSecondsOfZerosAndClearsOnSound() {
        var detector = SilenceDetector(threshold: 10)
        let second = [Float](repeating: 0, count: CaptureFormat.sampleRate)
        for _ in 0..<9 { detector.feed(second) }
        XCTAssertFalse(detector.isSilent)
        detector.feed(second)
        XCTAssertTrue(detector.isSilent)
        detector.feed([0.2])
        XCTAssertFalse(detector.isSilent)
        for _ in 0..<12 { detector.feed(second) }
        XCTAssertFalse(detector.isSilent)
    }

    func testResamplerIdentityHalvesAndDoublesAndIsChunkIndependent() {
        var same = LinearResampler(from: 48_000)
        XCTAssertEqual(same.process([1, 2, 3]), [1, 2, 3])
        let ramp = (0..<960).map { Float($0) }
        var down = LinearResampler(from: 96_000)
        XCTAssertEqual(down.process(ramp).count, 480, accuracy: 1)
        var up = LinearResampler(from: 24_000)
        let doubled = up.process(ramp)
        XCTAssertEqual(doubled.count, 1918, accuracy: 2)
        XCTAssertEqual(doubled[1], 0.5, accuracy: 0.001)
        var whole = LinearResampler(from: 44_100)
        var chunked = LinearResampler(from: 44_100)
        let all = whole.process(ramp)
        let pieces = chunked.process(Array(ramp[0..<333])) + chunked.process(Array(ramp[333..<960]))
        XCTAssertEqual(pieces, all)
    }

    func testDownmixAveragesChannels() {
        let interleaved: [Float] = [1, 3, 2, 4]
        let mono = interleaved.withUnsafeBufferPointer { MonoDownmix.interleaved($0, channels: 2) }
        XCTAssertEqual(mono, [2, 3])
        let a: [Float] = [1, 1], b: [Float] = [3, 5]
        let planar = a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in MonoDownmix.planar([pa, pb]) } }
        XCTAssertEqual(planar, [2, 3])
    }

    func testCallAppCatalogMatchesExactAndHelperBundleIDs() {
        XCTAssertEqual(CallAppCatalog.app(forBundleID: "us.zoom.xos")?.name, "Zoom")
        XCTAssertEqual(CallAppCatalog.app(forBundleID: "com.google.Chrome.helper")?.kind, .browser)
        XCTAssertEqual(CallAppCatalog.app(forBundleID: "com.microsoft.teams2")?.name, "Teams")
        XCTAssertNil(CallAppCatalog.app(forBundleID: "com.apple.Music"))
        XCTAssertEqual(Set(CallAppCatalog.all.map(\.bundleID)).count, CallAppCatalog.all.count)
    }

    func testSupportGateMessagesOnlyBelow14Dot2() {
        let old = OperatingSystemVersion(majorVersion: 14, minorVersion: 1, patchVersion: 0)
        let ok = OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)
        let newer = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        XCTAssertEqual(MeetingCaptureSupport.unsupportedMessage(for: old), "Gravar reuniões precisa do macOS 14.2 ou mais novo. Este Mac está no macOS 14.1.")
        XCTAssertNil(MeetingCaptureSupport.unsupportedMessage(for: ok))
        XCTAssertNil(MeetingCaptureSupport.unsupportedMessage(for: newer))
    }

    func testStartWritesMetaAndStopFinalizesStereoFileWithDuration() throws {
        let mic = FakeSource(name: "mic"), system = FakeSource(name: "sys"), sink = MemorySink()
        let converter = FakeConverter()
        let rec = recorder(mic: mic, system: system, sink: sink, converter: converter)
        let folder = try rec.start(detectedApp: "us.zoom.xos", now: t0)
        XCTAssertTrue(rec.isRecording)
        XCTAssertEqual(try RecordingFolder.read(in: folder).status, .recording)
        for _ in 0..<10 {
            mic.emit([Float](repeating: 0.5, count: CaptureFormat.sampleRate / 10))
            system.emit([Float](repeating: -0.5, count: CaptureFormat.sampleRate / 10))
        }
        let result = try rec.stop()
        XCTAssertFalse(rec.isRecording)
        XCTAssertTrue(sink.finished)
        XCTAssertEqual(sink.frames.count, CaptureFormat.sampleRate * 2)
        XCTAssertEqual(sink.frames[0], 0.5)
        XCTAssertEqual(sink.frames[1], -0.5)
        XCTAssertEqual(result.durationSeconds, 1, accuracy: 0.0001)
        XCTAssertNil(result.failure)
        XCTAssertEqual(converter.calls.map { $0.0.lastPathComponent }, ["audio.caf"])
        XCTAssertEqual(result.audioURL.lastPathComponent, "audio.m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.audioURL.path))
        let meta = try RecordingFolder.read(in: folder)
        XCTAssertEqual(meta.status, .transcribing)
        XCTAssertEqual(meta.detectedApp, "us.zoom.xos")
        XCTAssertEqual(meta.devices, .init(mic: "mic", system: "sys"))
        XCTAssertEqual(meta.durationSeconds ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(mic.stopped, 1)
        XCTAssertEqual(system.stopped, 1)
    }

    func testSecondStartAndStopWithoutRecordingAreRejected() throws {
        let rec = recorder()
        XCTAssertThrowsError(try rec.stop()) { XCTAssertEqual($0 as? MeetingRecorderError, .notRecording) }
        try rec.start(now: t0)
        XCTAssertThrowsError(try rec.start(now: t0)) { XCTAssertEqual($0 as? MeetingRecorderError, .alreadyRecording) }
    }

    func testLowDiskRefusesToStartAndLeavesNoFolder() throws {
        let rec = recorder(disk: 10_000_000)
        XCTAssertThrowsError(try rec.start(now: t0)) { XCTAssertEqual($0 as? MeetingRecorderError, .lowDisk(freeBytes: 10_000_000)) }
        XCTAssertFalse(rec.isRecording)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testUnsupportedSystemRefusesWithMessageAndTouchesNothing() throws {
        let mic = FakeSource(name: "mic")
        let rec = recorder(mic: mic, unsupported: "precisa do macOS 14.2")
        XCTAssertThrowsError(try rec.start(now: t0)) { XCTAssertEqual($0 as? MeetingRecorderError, .unsupported("precisa do macOS 14.2")) }
        XCTAssertEqual(mic.started, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testSystemSourceFailureStopsMicRemovesFolderAndReports() throws {
        let mic = FakeSource(name: "mic"), system = FakeSource(name: "sys"), sink = MemorySink()
        system.failOnStart = "sem permissão"
        let rec = recorder(mic: mic, system: system, sink: sink)
        XCTAssertThrowsError(try rec.start(now: t0)) { XCTAssertEqual($0 as? MeetingRecorderError, .source("sem permissão")) }
        XCTAssertFalse(rec.isRecording)
        XCTAssertEqual(mic.stopped, 1)
        XCTAssertTrue(sink.finished)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testWriteFailureIsReportedByHealthAndMarksMetaFailedOnStop() throws {
        let mic = FakeSource(name: "mic"), system = FakeSource(name: "sys"), sink = MemorySink()
        let rec = recorder(mic: mic, system: system, sink: sink)
        let folder = try rec.start(now: t0)
        XCTAssertNil(rec.health())
        sink.failWrites = true
        mic.emit([1, 1])
        system.emit([1, 1])
        rec.pump()
        XCTAssertNotNil(rec.health())
        let result = try rec.stop()
        XCTAssertNotNil(result.failure)
        let meta = try RecordingFolder.read(in: folder)
        XCTAssertEqual(meta.status, .failed)
        XCTAssertNotNil(meta.failure)
    }

    func testHealthFlagsDiskRunningOut() throws {
        let rec = recorder(disk: 100_000_000)
        XCTAssertThrowsError(try rec.start(now: t0))
        let roomy = recorder(disk: 5_000_000_000)
        try roomy.start(now: t0)
        XCTAssertNil(roomy.health())
    }

    func testSamplesAfterStopAreIgnored() throws {
        let mic = FakeSource(name: "mic"), sink = MemorySink()
        let rec = recorder(mic: mic, sink: sink)
        try rec.start(now: t0)
        try rec.stop()
        let before = sink.frames.count
        mic.emit([1, 1, 1])
        rec.pump()
        XCTAssertEqual(sink.frames.count, before)
    }

    func testStalledSourceRaisesWarningAfterFiveSecondsAndClearsWhenItReturns() throws {
        let mic = FakeSource(name: "mic"), system = FakeSource(name: "sys"), clock = ClockBox()
        let rec = recorder(mic: mic, system: system, clock: clock)
        try rec.start(now: t0)
        let chunk = [Float](repeating: 0.1, count: 4800)
        mic.emit(chunk)
        system.emit(chunk)
        clock.now = 4
        rec.pump()
        XCTAssertEqual(rec.warnings(), [])
        mic.emit(chunk)
        clock.now = 9.5
        rec.pump()
        XCTAssertEqual(rec.warnings(), [.systemStalled])
        XCTAssertEqual(RecordingWarning.systemStalled.message, "o áudio do Mac parou")
        system.emit(chunk)
        clock.now = 10
        rec.pump()
        XCTAssertEqual(rec.warnings(), [])
        clock.now = 16
        system.emit(chunk)
        rec.pump()
        XCTAssertEqual(rec.warnings(), [.micStalled])
        XCTAssertEqual(RecordingWarning.micStalled.message, "o microfone parou")
    }

    func testSourceThatNeverDeliversIsFlaggedFromTheStart() throws {
        let clock = ClockBox()
        let rec = recorder(clock: clock)
        try rec.start(now: t0)
        clock.now = 5
        rec.pump()
        XCTAssertEqual(rec.warnings(), [.micStalled, .systemStalled])
    }

    func testAllZeroSystemChannelWarnsAfterTenSecondsThenClearsWhenSoundArrives() throws {
        let mic = FakeSource(name: "mic"), system = FakeSource(name: "sys"), clock = ClockBox()
        let rec = recorder(mic: mic, system: system, clock: clock)
        try rec.start(now: t0)
        let second = [Float](repeating: 0, count: CaptureFormat.sampleRate)
        for index in 1...9 {
            mic.emit(second)
            system.emit(second)
            clock.now = Double(index)
            rec.pump()
        }
        XCTAssertEqual(rec.warnings(), [])
        mic.emit(second)
        system.emit(second)
        clock.now = 10
        rec.pump()
        XCTAssertEqual(rec.warnings(), [.systemSilent])
        XCTAssertEqual(
            RecordingWarning.systemSilent.message,
            "não estou ouvindo o áudio do Mac: libere em Ajustes do Sistema › Privacidade › Gravação de áudio"
        )
        mic.emit(second)
        system.emit([0.3])
        clock.now = 11
        rec.pump()
        XCTAssertEqual(rec.warnings(), [])
    }

    func testStopKeepsRawAudioAndReportsWhenConversionFails() throws {
        let converter = FakeConverter()
        converter.failure = "encoder"
        let mic = FakeSource(name: "mic"), system = FakeSource(name: "sys")
        let rec = recorder(mic: mic, system: system, converter: converter)
        let folder = try rec.start(now: t0)
        mic.emit([1, 1])
        system.emit([1, 1])
        let result = try rec.stop()
        XCTAssertNotNil(result.failure)
        XCTAssertEqual(result.audioURL.lastPathComponent, "audio.caf")
        XCTAssertEqual(try RecordingFolder.read(in: folder).status, .failed)
    }

    private func leftover(_ name: String, status: RecordingStatus, rawBytes: Int?) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try RecordingFolder.write(RecordingMeta(startedAt: t0, devices: .init(mic: nil, system: nil), status: status), in: folder)
        if let rawBytes { try Data(count: rawBytes).write(to: RecordingFolder.rawAudioURL(in: folder)) }
        return folder
    }

    func testRecoveryConvertsLeftoverRecordingMarksItInterruptedAndDropsTheRaw() throws {
        let broken = try leftover("2027-01-15_08-00-00", status: .recording, rawBytes: 100)
        let done = try leftover("2027-01-15_09-00-00", status: .transcribing, rawBytes: nil)
        let converter = FakeConverter()
        let recovered = RecordingRecovery.recover(root: root, converter: converter)
        XCTAssertEqual(recovered, [RecoveredRecording(folder: broken, durationSeconds: 3, failure: nil)])
        XCTAssertEqual(converter.calls.count, 1)
        let meta = try RecordingFolder.read(in: broken)
        XCTAssertEqual(meta.status, .interrupted)
        XCTAssertEqual(meta.durationSeconds, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingFolder.audioURL(in: broken).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: RecordingFolder.rawAudioURL(in: broken).path))
        XCTAssertEqual(try RecordingFolder.read(in: done).status, .transcribing)
        XCTAssertTrue(RecordingRecovery.recover(root: root, converter: converter).isEmpty)
        XCTAssertEqual(converter.calls.count, 1)
        let raw = try String(contentsOf: RecordingFolder.metaURL(in: broken), encoding: .utf8)
        XCTAssertTrue(raw.contains("\"interrompida\""))
    }

    func testRecoveryKeepsRawAndMarksFailedWhenConversionFailsOrAudioIsEmpty() throws {
        let unreadable = try leftover("a", status: .recording, rawBytes: 100)
        let empty = try leftover("b", status: .recording, rawBytes: 0)
        let missing = try leftover("c", status: .recording, rawBytes: nil)
        let converter = FakeConverter()
        converter.failure = "arquivo truncado"
        let recovered = RecordingRecovery.recover(root: root, converter: converter)
        XCTAssertEqual(recovered.count, 3)
        XCTAssertTrue(recovered.allSatisfy { $0.failure != nil })
        for folder in [unreadable, empty, missing] {
            XCTAssertEqual(try RecordingFolder.read(in: folder).status, .failed)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingFolder.rawAudioURL(in: unreadable).path))
        XCTAssertEqual(converter.calls.count, 1)
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testCreatedRootFolderMetaAndAudioAreOwnerOnly() throws {
        let nested = root.appendingPathComponent("Wisp/reunioes", isDirectory: true)
        let folder = try RecordingFolder.create(root: nested, date: t0, timeZone: utc)
        try RecordingFolder.write(RecordingMeta(startedAt: t0, devices: .init(mic: nil, system: nil)), in: folder)
        let raw = RecordingFolder.rawAudioURL(in: folder)
        let encoded = RecordingFolder.audioURL(in: folder)
        let sink = try StereoFileSink(url: raw, container: .pcm16)
        try sink.write([Float](repeating: 0.1, count: CaptureFormat.sampleRate * 2))
        _ = try M4AFileConverter().convert(from: raw, to: encoded)
        try sink.finish()
        XCTAssertEqual(try permissions(nested), 0o700)
        XCTAssertEqual(try permissions(folder), 0o700)
        for file in [RecordingFolder.metaURL(in: folder), raw, encoded] {
            XCTAssertEqual(try permissions(file), 0o600, file.lastPathComponent)
        }
    }

    func testExistingRootKeepsItsPermissions() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        _ = try RecordingFolder.create(root: root, date: t0, timeZone: utc)
        XCTAssertEqual(try permissions(root), 0o755)
    }

    func testRecoveryNeverTouchesTheActiveRecordingFolder() throws {
        let live = try leftover("2027-01-15_08-00-00", status: .recording, rawBytes: 100)
        let old = try leftover("2027-01-14_08-00-00", status: .recording, rawBytes: 100)
        let converter = FakeConverter()
        let recovered = RecordingRecovery.recover(root: root, converter: converter, excluding: [live.lastPathComponent])
        XCTAssertEqual(recovered.map(\.folder), [old])
        XCTAssertEqual(converter.calls.map { $0.0.deletingLastPathComponent() }, [old])
        XCTAssertEqual(try RecordingFolder.read(in: live).status, .recording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: RecordingFolder.rawAudioURL(in: live).path))
    }

    func testStopCaptureOnlyKeepsRawAndLeavesMetaForRecoveryWithoutEncoding() throws {
        let mic = FakeSource(name: "mic"), system = FakeSource(name: "sys"), sink = MemorySink()
        let converter = FakeConverter()
        let rec = recorder(mic: mic, system: system, sink: sink, converter: converter)
        let folder = try rec.start(now: t0)
        mic.emit([Float](repeating: 0.5, count: CaptureFormat.sampleRate))
        system.emit([Float](repeating: 0.5, count: CaptureFormat.sampleRate))
        rec.stopCaptureOnly()
        XCTAssertFalse(rec.isRecording)
        XCTAssertTrue(sink.finished)
        XCTAssertTrue(converter.calls.isEmpty)
        let meta = try RecordingFolder.read(in: folder)
        XCTAssertEqual(meta.status, .recording)
        XCTAssertEqual(meta.durationSeconds ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(mic.stopped, 1)
        XCTAssertEqual(system.stopped, 1)
    }

    func testRecoveryOfMissingRootIsEmpty() {
        XCTAssertTrue(RecordingRecovery.recover(root: root.appendingPathComponent("nope"), converter: FakeConverter()).isEmpty)
    }

    func testRealConverterTurnsAPCMFileIntoStereoM4AEvenIfTheWriterWasNeverClosed() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let raw = root.appendingPathComponent("audio.caf")
        let encoded = root.appendingPathComponent("audio.m4a")
        let sink = try StereoFileSink(url: raw, container: .pcm16)
        var frames = [Float](repeating: 0, count: CaptureFormat.sampleRate * 2)
        for index in 0..<CaptureFormat.sampleRate { frames[index * 2 + 1] = 0.4 * sin(Float(index) * 2 * .pi * 300 / Float(CaptureFormat.sampleRate)) }
        try sink.write(frames)
        let duration = try M4AFileConverter().convert(from: raw, to: encoded)
        XCTAssertEqual(duration, 1, accuracy: 0.1)
        let file = try AVAudioFile(forReading: encoded)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        XCTAssertEqual(Double(file.length), Double(CaptureFormat.sampleRate), accuracy: 6_000)
        try sink.finish()
    }

    func testM4AFileSinkWritesReadableStereoFileWithChannelsApart() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("audio.m4a")
        let sink = try StereoFileSink(url: url, container: .m4a)
        var frames = [Float](repeating: 0, count: CaptureFormat.sampleRate * 2)
        for index in 0..<CaptureFormat.sampleRate {
            frames[index * 2] = 0.5 * sin(Float(index) * 2 * .pi * 440 / Float(CaptureFormat.sampleRate))
        }
        try sink.write(frames)
        try sink.finish()
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        XCTAssertEqual(Double(file.length), Double(CaptureFormat.sampleRate), accuracy: 4_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let data = try XCTUnwrap(buffer.floatChannelData)
        func rms(_ channel: Int) -> Float {
            let count = Int(buffer.frameLength)
            return sqrt((0..<count).reduce(Float(0)) { $0 + data[channel][$1] * data[channel][$1] } / Float(count))
        }
        XCTAssertGreaterThan(rms(0), 0.2)
        XCTAssertLessThan(rms(1), 0.02)
    }

    func testMicOnlyNeverStartsTheSystemSourceNorWarnsAboutIt() throws {
        let mic = FakeSource(name: "mic"), system = FakeSource(name: "sys"), clock = ClockBox()
        let base = root!
        let rec = MeetingRecorder(
            mic: mic, system: system, root: { base }, makeSink: { _ in MemorySink() }, converter: FakeConverter(),
            diskSpace: FixedDisk(bytes: 50_000_000_000), unsupportedMessage: { nil }, clock: { clock.now },
            autoPump: false, timeZone: utc, sources: .mic
        )
        let folder = try rec.start(now: t0)
        XCTAssertEqual(system.started, 0)
        XCTAssertEqual(mic.started, 1)
        for second in 1...12 {
            mic.emit([Float](repeating: 0.2, count: CaptureFormat.sampleRate))
            clock.now = Double(second)
            rec.pump()
        }
        XCTAssertEqual(rec.warnings(), [])
        let meta = try RecordingFolder.read(in: folder)
        XCTAssertEqual(meta.sources, .mic)
        XCTAssertNil(meta.devices.system)
        _ = try rec.stop()
        XCTAssertEqual(system.stopped, 0)
    }

    func testSystemOnlyNeverStartsTheMicrophone() throws {
        let mic = FakeSource(name: "mic"), system = FakeSource(name: "sys")
        let base = root!
        let rec = MeetingRecorder(
            mic: mic, system: system, root: { base }, makeSink: { _ in MemorySink() }, converter: FakeConverter(),
            diskSpace: FixedDisk(bytes: 50_000_000_000), unsupportedMessage: { nil }, autoPump: false, timeZone: utc, sources: .system
        )
        try rec.start(now: t0)
        XCTAssertEqual(mic.started, 0)
        XCTAssertEqual(system.started, 1)
        _ = try rec.stop()
        XCTAssertEqual(mic.stopped, 0)
    }

    func testAudioObserverGetsMonoSamplesPerChannelAndLevelsMoveWithTheSignal() throws {
        final class Heard: @unchecked Sendable {
            let lock = NSLock()
            var counts: [AudioChannel: Int] = [:]
            func add(_ channel: AudioChannel, _ count: Int) { lock.withLock { counts[channel, default: 0] += count } }
        }
        let heard = Heard()
        let mic = FakeSource(name: "mic"), system = FakeSource(name: "sys")
        let base = root!
        let rec = MeetingRecorder(
            mic: mic, system: system, root: { base }, makeSink: { _ in MemorySink() }, converter: FakeConverter(),
            diskSpace: FixedDisk(bytes: 50_000_000_000), unsupportedMessage: { nil }, autoPump: false, timeZone: utc,
            onAudio: { channel, samples, _ in heard.add(channel, samples.count) }
        )
        try rec.start(now: t0)
        mic.emit([Float](repeating: 0.5, count: 4800))
        system.emit([Float](repeating: 0, count: 4800))
        rec.pump()
        XCTAssertEqual(heard.counts[.mic], 4800)
        XCTAssertEqual(heard.counts[.system], 4800)
        let loud = rec.levels()
        XCTAssertGreaterThan(loud.mic, 0.8)
        XCTAssertEqual(loud.system, 0)
        for _ in 0..<40 { rec.pump() }
        XCTAssertLessThan(rec.levels().mic, 0.05)
        _ = try rec.stop()
        XCTAssertEqual(rec.levels().mic, 0)
    }

    func testElapsedClockFormat() {
        XCTAssertEqual(ElapsedFormat.clock(-3), "0:00")
        XCTAssertEqual(ElapsedFormat.clock(7.9), "0:07")
        XCTAssertEqual(ElapsedFormat.clock(754), "12:34")
        XCTAssertEqual(ElapsedFormat.clock(3723), "1:02:03")
    }

    func testSettingsKeepRecordingsPath() throws {
        var settings = WispSettings()
        settings.recordingsPath = "~/Gravacoes"
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(WispSettings.self, from: data).recordingsPath, "~/Gravacoes")
        XCTAssertNil(try JSONDecoder().decode(WispSettings.self, from: Data(#"{"theme":"lime"}"#.utf8)).recordingsPath)
    }

    func testAnActiveRecordingIsOneWithRecordingStatusTouchedInTheLastMinute() throws {
        let folder = try RecordingFolder.create(root: root, date: t0, timeZone: utc)
        let meta = RecordingMeta(startedAt: t0, devices: .init(mic: nil, system: nil), status: .recording)
        try RecordingFolder.write(meta, in: folder)
        XCTAssertTrue(RecordingFolder.hasActiveRecording(in: root))
        XCTAssertFalse(RecordingFolder.hasActiveRecording(in: root, now: Date().addingTimeInterval(120)))
        var finished = meta
        finished.status = .transcribing
        try RecordingFolder.write(finished, in: folder)
        XCTAssertFalse(RecordingFolder.hasActiveRecording(in: root))
    }

    func testAFolderNotTouchedInTheLastMinuteIsNotEvenRead() throws {
        let folder = try RecordingFolder.create(root: root, date: t0, timeZone: utc)
        try RecordingFolder.write(RecordingMeta(startedAt: t0, devices: .init(mic: nil, system: nil), status: .recording), in: folder)
        let old = Date().addingTimeInterval(-600)
        for url in [folder, RecordingFolder.metaURL(in: folder)] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        XCTAssertFalse(RecordingFolder.hasActiveRecording(in: root))
    }
}
