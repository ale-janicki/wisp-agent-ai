import Foundation

public protocol SpeechRecognizer: Sendable {
    var engineName: String { get }
    func transcribe(_ samples: [Float], language: String?) async throws -> [RecognizedSpan]
    func unload() async
}

public extension SpeechRecognizer {
    func unload() async {}
}

public struct MeetingPauseGate: Sendable {
    public var isRecording: @Sendable () async -> Bool
    public var recognizer: SpeechRecognizer
    public var interval: Duration

    public init(recognizer: SpeechRecognizer, interval: Duration = .seconds(1), isRecording: @escaping @Sendable () async -> Bool) {
        self.recognizer = recognizer
        self.interval = interval
        self.isRecording = isRecording
    }

    public func wait() async throws {
        guard await isRecording() else { return }
        await recognizer.unload()
        while await isRecording() { try await Task.sleep(for: interval) }
    }
}

public final class MeetingTranscriptStore: @unchecked Sendable {
    private let lock = NSLock()
    private var merger = TranscriptMerger()
    private var failedSegments = 0
    private let startedAt: Date
    private let engine: String
    private let language: String
    private let folder: URL?

    public init(startedAt: Date, engine: String, language: String = "auto", folder: URL? = nil) {
        self.startedAt = startedAt
        self.engine = engine
        self.language = language
        self.folder = folder
    }

    public var snapshot: [MeetingSegment] { lock.withLock { merger.snapshot } }

    public var finals: [MeetingSegment] { lock.withLock { merger.finals } }

    public func setPartial(_ span: RecognizedSpan?, channel: AudioChannel) {
        lock.withLock { merger.setPartial(span, channel: channel) }
    }

    public func commit(_ spans: [RecognizedSpan], channel: AudioChannel) {
        let saved = lock.withLock { () -> MeetingTranscriptDocument? in
            merger.commit(spans, channel: channel)
            guard folder != nil else { return nil }
            return document(duration: merger.finals.map(\.end).max() ?? 0, segments: merger.finals)
        }
        if let saved, let folder { try? MeetingTranscriptFile.write(saved, in: folder, live: true) }
    }

    public func recordFailure() {
        lock.withLock { failedSegments += 1 }
    }

    public func document(duration: Double) -> MeetingTranscriptDocument {
        lock.withLock { document(duration: duration, segments: merger.finals) }
    }

    private func document(duration: Double, segments: [MeetingSegment]) -> MeetingTranscriptDocument {
        var made = MeetingTranscriptDocument(
            startedAt: startedAt, durationSeconds: duration, language: language, engine: engine, segments: segments
        )
        made.failedSegments = failedSegments > 0 ? failedSegments : nil
        return made
    }
}

public final class LiveTranscriber: @unchecked Sendable {
    public static let lagThreshold = 3

    private let recognizer: SpeechRecognizer
    private let store: MeetingTranscriptStore
    private let language: String?
    private let onUpdate: @Sendable ([MeetingSegment]) -> Void
    private let onFailure: @Sendable (String) -> Void
    private let onLag: @Sendable (Bool) -> Void
    private var lagging = false
    private let lock = NSLock()
    private var decimators: [AudioChannel: Decimator48To16] = [:]
    private var streamers: [AudioChannel: ChannelStreamer]
    private var pending: [StreamJob] = []
    private var failureReported = false
    private let signals: AsyncStream<Void>
    private let wake: AsyncStream<Void>.Continuation
    private var worker: Task<Void, Never>?

    public init(
        recognizer: SpeechRecognizer, store: MeetingTranscriptStore, language: String? = nil,
        config: ChannelStreamerConfig = .default, channels: Set<AudioChannel> = Set(AudioChannel.allCases),
        onUpdate: @escaping @Sendable ([MeetingSegment]) -> Void, onFailure: @escaping @Sendable (String) -> Void = { _ in },
        onLag: @escaping @Sendable (Bool) -> Void = { _ in }
    ) {
        self.onLag = onLag
        self.recognizer = recognizer
        self.store = store
        self.language = language
        self.onUpdate = onUpdate
        self.onFailure = onFailure
        var made: [AudioChannel: ChannelStreamer] = [:]
        for channel in channels { made[channel] = ChannelStreamer(channel: channel, config: config) }
        streamers = made
        (signals, wake) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        worker = Task { [weak self] in await self?.run() }
    }

    public func push48k(_ samples: [Float], channel: AudioChannel) {
        push16k(lock.withLock { () -> [Float] in
            var decimator = decimators[channel] ?? Decimator48To16()
            let out = decimator.process(samples)
            decimators[channel] = decimator
            return out
        }, channel: channel)
    }

    public var hasFailed: Bool { lock.withLock { failureReported } }

    public func skipGap(seconds: Double, channel: AudioChannel) {
        let jobs = lock.withLock { () -> [StreamJob] in
            decimators[channel] = Decimator48To16()
            guard var streamer = streamers[channel] else { return [] }
            let made = streamer.skipGap(samples: Int(seconds * Double(SpeechAudio.sampleRate)))
            streamers[channel] = streamer
            return made
        }
        enqueue(jobs)
    }

    public func push16k(_ samples: [Float], channel: AudioChannel) {
        guard !samples.isEmpty else { return }
        let jobs = lock.withLock { () -> [StreamJob] in
            guard var streamer = streamers[channel] else { return [] }
            let made = streamer.append(samples)
            streamers[channel] = streamer
            return made
        }
        enqueue(jobs)
    }

    public func finish() async -> [MeetingSegment] {
        let jobs = lock.withLock { () -> [StreamJob] in
            var made: [StreamJob] = []
            for channel in AudioChannel.allCases {
                guard var streamer = streamers[channel] else { continue }
                made += streamer.flush()
                streamers[channel] = streamer
            }
            return made
        }
        enqueue(jobs)
        wake.finish()
        await worker?.value
        return store.snapshot
    }

    public func cancel() {
        lock.withLock { pending.removeAll() }
        wake.finish()
        worker?.cancel()
    }

    public func stopAndWait() async {
        cancel()
        await worker?.value
    }

    private func enqueue(_ jobs: [StreamJob]) {
        guard !jobs.isEmpty else { return }
        let changed = lock.withLock { () -> Bool? in
            for job in jobs {
                if job.kind == .typing, pending.contains(where: { $0.channel == job.channel }) { continue }
                pending.append(job)
            }
            let behind = pending.filter { $0.kind == .final }.count >= Self.lagThreshold
            guard behind != lagging else { return nil }
            lagging = behind
            return behind
        }
        if let changed { onLag(changed) }
        wake.yield()
    }

    private func take() -> StreamJob? {
        let taken = lock.withLock { () -> (StreamJob?, Bool?) in
            guard !pending.isEmpty else { return (nil, nil) }
            let job = pending.removeFirst()
            let behind = pending.filter { $0.kind == .final }.count >= Self.lagThreshold
            defer { lagging = behind }
            return (job, behind == lagging ? nil : behind)
        }
        if let changed = taken.1 { onLag(changed) }
        return taken.0
    }

    private func run() async {
        for await _ in signals {
            while let job = take() { await process(job) }
        }
        while let job = take() { await process(job) }
    }

    private func process(_ job: StreamJob) async {
        if job.kind == .typing {
            store.setPartial(RecognizedSpan(text: "…", start: job.startSeconds, end: job.startSeconds), channel: job.channel)
            onUpdate(store.snapshot)
            return
        }
        if job.samples.isEmpty {
            store.commit([], channel: job.channel)
            onUpdate(store.snapshot)
            return
        }
        do {
            let spans = try await recognizer.transcribe(job.samples, language: language).map {
                RecognizedSpan(
                    text: $0.text, start: $0.start + job.startSeconds, end: $0.end + job.startSeconds, confidence: $0.confidence
                )
            }
            guard !Task.isCancelled else { return }
            store.commit(spans, channel: job.channel)
            onUpdate(store.snapshot)
        } catch {
            let first = lock.withLock { () -> Bool in
                defer { failureReported = true }
                return !failureReported
            }
            store.recordFailure()
            store.commit([], channel: job.channel)
            onUpdate(store.snapshot)
            if first { onFailure(error.localizedDescription) }
        }
    }
}
