import Foundation

public protocol AudioSource: AnyObject, Sendable {
    var deviceName: String? { get }
    func start(ring: CaptureRing) throws
    func stop()
}

public protocol AudioFileSink: AnyObject, Sendable {
    func write(_ frames: [Float]) throws
    func finish() throws
}

public protocol DiskSpace: Sendable {
    func availableBytes(at url: URL) -> Int64?
}

public struct VolumeDiskSpace: DiskSpace {
    public init() {}

    public func availableBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

public enum MeetingRecorderError: Error, Equatable, LocalizedError {
    case alreadyRecording
    case notRecording
    case unsupported(String)
    case lowDisk(freeBytes: Int64)
    case source(String)
    case sink(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording: "Já tem uma gravação em andamento."
        case .notRecording: "Não tem gravação em andamento."
        case .unsupported(let message): message
        case .lowDisk(let free): "Pouco espaço em disco para gravar (\(free / 1_000_000) MB livres)."
        case .source(let message): "Não consegui capturar o áudio: \(message)"
        case .sink(let message): "Não consegui gravar o arquivo de áudio: \(message)"
        }
    }
}

public struct RecordingResult: Equatable, Sendable {
    public var folder: URL
    public var audioURL: URL
    public var durationSeconds: Double
    public var failure: String?
}

public final class MeetingRecorder: @unchecked Sendable {
    public static let defaultMinimumFreeBytes: Int64 = 1_000_000_000
    public static let defaultStopFreeBytes: Int64 = 200_000_000
    private static let pumpInterval: DispatchTimeInterval = .milliseconds(50)
    private static let levelDecay: Float = 0.85

    private struct Lane {
        var frames = 0
        var rate = 0.0
        var resampler = LinearResampler(from: Double(CaptureFormat.sampleRate))

        mutating func mono(_ slot: RingSlot) -> [Float] {
            if slot.rate != rate {
                rate = slot.rate
                resampler = LinearResampler(from: rate)
            }
            let mono = resampler.process(MonoDownmix.interleaved(slot.samples, channels: slot.channels))
            frames += mono.count
            return mono
        }
    }

    private final class Session {
        let folder: URL
        var meta: RecordingMeta
        let sink: AudioFileSink
        let micRing = CaptureRing()
        let systemRing = CaptureRing()
        var mixer = StereoMixer()
        var micLane = Lane()
        var systemLane = Lane()
        var micWatch = StallWatchdog()
        var systemWatch = StallWatchdog()
        var silence = SilenceDetector()
        var warnings: [RecordingWarning] = []
        var framesWritten = 0
        var micLevel: Float = 0
        var systemLevel: Float = 0
        var failure: String?
        var timer: DispatchSourceTimer?

        init(folder: URL, meta: RecordingMeta, sink: AudioFileSink) {
            self.folder = folder
            self.meta = meta
            self.sink = sink
        }
    }

    private let mic: AudioSource
    private let system: AudioSource
    private let root: @Sendable () -> URL
    private let makeSink: @Sendable (URL) throws -> AudioFileSink
    private let converter: AudioFileConverter
    private let diskSpace: DiskSpace
    private let unsupportedMessage: @Sendable () -> String?
    private let clock: @Sendable () -> TimeInterval
    private let autoPump: Bool
    private let minimumFreeBytes: Int64
    private let stopFreeBytes: Int64
    private let timeZone: TimeZone
    private let sources: RecordingSources
    private let onAudio: (@Sendable (AudioChannel, [Float], Double) -> Void)?
    private let writer = DispatchQueue(label: "\(AppIdentity.bundleID).meetings.writer", qos: .userInitiated)
    private var session: Session?

    public init(
        mic: AudioSource,
        system: AudioSource,
        root: @escaping @Sendable () -> URL,
        makeSink: @escaping @Sendable (URL) throws -> AudioFileSink,
        converter: AudioFileConverter,
        diskSpace: DiskSpace = VolumeDiskSpace(),
        unsupportedMessage: @escaping @Sendable () -> String? = { MeetingCaptureSupport.unsupportedMessage() },
        clock: @escaping @Sendable () -> TimeInterval = { HostClock.nowSeconds() },
        autoPump: Bool = true,
        minimumFreeBytes: Int64 = MeetingRecorder.defaultMinimumFreeBytes,
        stopFreeBytes: Int64 = MeetingRecorder.defaultStopFreeBytes,
        timeZone: TimeZone = .current,
        sources: RecordingSources = .both,
        onAudio: (@Sendable (AudioChannel, [Float], Double) -> Void)? = nil
    ) {
        self.mic = mic
        self.system = system
        self.root = root
        self.makeSink = makeSink
        self.converter = converter
        self.diskSpace = diskSpace
        self.unsupportedMessage = unsupportedMessage
        self.clock = clock
        self.autoPump = autoPump
        self.minimumFreeBytes = minimumFreeBytes
        self.stopFreeBytes = stopFreeBytes
        self.timeZone = timeZone
        self.sources = sources
        self.onAudio = onAudio
    }

    public var isRecording: Bool { writer.sync { session != nil } }

    @discardableResult
    public func start(detectedApp: String? = nil, now: Date = Date()) throws -> URL {
        try writer.sync { try startOnWriter(detectedApp: detectedApp, now: now) }
    }

    @discardableResult
    public func stop() throws -> RecordingResult {
        try writer.sync { try stopOnWriter() }
    }

    /// Stops capture and closes the raw file but leaves the meta as `.recording`, so the next launch's
    /// recovery does the encode. For app termination, where encoding would block the main thread.
    public func stopCaptureOnly() {
        writer.sync {
            guard let ending = session else { return }
            ending.timer?.cancel()
            ending.timer = nil
            stopSources()
            pumpOnWriter(ending, flush: true)
            session = nil
            try? ending.sink.finish()
            ending.meta.durationSeconds = Double(ending.framesWritten) / Double(CaptureFormat.sampleRate)
            try? RecordingFolder.write(ending.meta, in: ending.folder)
        }
    }

    public func pump() {
        writer.sync {
            guard let session else { return }
            pumpOnWriter(session, flush: false)
        }
    }

    public func health() -> String? {
        let current = writer.sync { session }
        guard let current else { return nil }
        if let failure = writer.sync(execute: { current.failure }) { return failure }
        guard let free = diskSpace.availableBytes(at: current.folder), free < stopFreeBytes else { return nil }
        return MeetingRecorderError.lowDisk(freeBytes: free).localizedDescription
    }

    public func levels() -> (mic: Float, system: Float) {
        writer.sync { (session?.micLevel ?? 0, session?.systemLevel ?? 0) }
    }

    public func warnings() -> [RecordingWarning] {
        writer.sync { session?.warnings ?? [] }
    }

    private func startOnWriter(detectedApp: String?, now: Date) throws -> URL {
        if let message = unsupportedMessage() { throw MeetingRecorderError.unsupported(message) }
        guard session == nil else { throw MeetingRecorderError.alreadyRecording }
        let base = root()
        let folder: URL
        do {
            folder = try RecordingFolder.create(root: base, date: now, timeZone: timeZone)
        } catch {
            throw MeetingRecorderError.sink(error.localizedDescription)
        }
        if let free = diskSpace.availableBytes(at: base), free < minimumFreeBytes {
            try? FileManager.default.removeItem(at: folder)
            throw MeetingRecorderError.lowDisk(freeBytes: free)
        }
        let sink: AudioFileSink
        do {
            sink = try makeSink(RecordingFolder.rawAudioURL(in: folder))
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw MeetingRecorderError.sink(error.localizedDescription)
        }
        let meta = RecordingMeta(
            startedAt: now,
            devices: .init(mic: sources.usesMic ? mic.deviceName : nil, system: sources.usesSystem ? system.deviceName : nil),
            detectedApp: detectedApp, sources: sources
        )
        let started = Session(folder: folder, meta: meta, sink: sink)
        let begin = clock()
        _ = started.micWatch.observe(totalFrames: 0, now: begin)
        _ = started.systemWatch.observe(totalFrames: 0, now: begin)
        session = started
        do {
            if sources.usesMic { try mic.start(ring: started.micRing) }
            if sources.usesSystem { try system.start(ring: started.systemRing) }
            try RecordingFolder.write(meta, in: folder)
        } catch {
            abandon(started)
            if let known = error as? MeetingRecorderError { throw known }
            throw MeetingRecorderError.source(error.localizedDescription)
        }
        if autoPump { startTimer(for: started) }
        return folder
    }

    private func stopOnWriter() throws -> RecordingResult {
        guard let ending = session else { throw MeetingRecorderError.notRecording }
        ending.timer?.cancel()
        ending.timer = nil
        stopSources()
        pumpOnWriter(ending, flush: true)
        session = nil
        do {
            try ending.sink.finish()
        } catch {
            ending.failure = ending.failure ?? MeetingRecorderError.sink(error.localizedDescription).localizedDescription
        }
        let duration = Double(ending.framesWritten) / Double(CaptureFormat.sampleRate)
        let raw = RecordingFolder.rawAudioURL(in: ending.folder)
        let encoded = RecordingFolder.audioURL(in: ending.folder)
        var audio = raw
        if ending.failure == nil || ending.framesWritten > 0 {
            do {
                _ = try converter.convert(from: raw, to: encoded)
                try? FileManager.default.removeItem(at: raw)
                audio = encoded
            } catch {
                ending.failure = ending.failure
                    ?? "não consegui gerar o \(RecordingFolder.audioFileName) (\(error.localizedDescription)); o áudio bruto ficou em \(RecordingFolder.rawAudioFileName)"
            }
        }
        ending.meta.durationSeconds = duration
        ending.meta.status = ending.failure == nil ? .transcribing : .failed
        ending.meta.failure = ending.failure
        try? RecordingFolder.write(ending.meta, in: ending.folder)
        return RecordingResult(folder: ending.folder, audioURL: audio, durationSeconds: duration, failure: ending.failure)
    }

    private func stopSources() {
        if sources.usesMic { mic.stop() }
        if sources.usesSystem { system.stop() }
    }

    private func startTimer(for started: Session) {
        let timer = DispatchSource.makeTimerSource(queue: writer)
        timer.schedule(deadline: .now() + Self.pumpInterval, repeating: Self.pumpInterval)
        timer.setEventHandler { [weak self, weak started] in
            guard let self, let started, self.session === started else { return }
            self.pumpOnWriter(started, flush: false)
        }
        started.timer = timer
        timer.resume()
    }

    private func abandon(_ failed: Session) {
        failed.timer?.cancel()
        session = nil
        stopSources()
        try? failed.sink.finish()
        try? FileManager.default.removeItem(at: failed.folder)
    }

    private func pumpOnWriter(_ current: Session, flush: Bool) {
        var micPeak: Float = 0
        var systemPeak: Float = 0
        while current.micRing.pop({ slot in
            let mono = current.micLane.mono(slot)
            micPeak = max(micPeak, SignalLevel.rms(mono))
            onAudio?(.mic, mono, slot.time)
            current.mixer.push(mic: mono, at: slot.time)
        }) {}
        while current.systemRing.pop({ slot in
            let mono = current.systemLane.mono(slot)
            systemPeak = max(systemPeak, SignalLevel.rms(mono))
            current.silence.feed(mono)
            onAudio?(.system, mono, slot.time)
            current.mixer.push(system: mono, at: slot.time)
        }) {}
        current.micLevel = max(SignalLevel.normalized(rms: micPeak), current.micLevel * Self.levelDecay)
        current.systemLevel = max(SignalLevel.normalized(rms: systemPeak), current.systemLevel * Self.levelDecay)
        let now = clock()
        let micStalled = sources.usesMic && current.micWatch.observe(totalFrames: current.micLane.frames, now: now)
        let systemStalled = sources.usesSystem && current.systemWatch.observe(totalFrames: current.systemLane.frames, now: now)
        var raised: Set<RecordingWarning> = []
        if micStalled { raised.insert(.micStalled) }
        if systemStalled { raised.insert(.systemStalled) }
        if sources.usesSystem, current.silence.isSilent, !systemStalled { raised.insert(.systemSilent) }
        if current.micRing.overrunCount > 0 || current.systemRing.overrunCount > 0 { raised.insert(.overrun) }
        current.warnings = RecordingWarning.allCases.filter(raised.contains)
        let frames = current.mixer.pull(flush: flush)
        guard !frames.isEmpty, current.failure == nil else { return }
        do {
            try current.sink.write(frames)
            current.framesWritten += frames.count / 2
        } catch {
            current.failure = MeetingRecorderError.sink(error.localizedDescription).localizedDescription
        }
    }
}
