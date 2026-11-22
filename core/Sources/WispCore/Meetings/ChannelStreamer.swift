import Foundation

public enum SpeechAudio {
    public static let sampleRate = 16_000
}

public struct Decimator48To16: Sendable {
    private var carry: [Float] = []

    public init() {}

    public mutating func process(_ input: [Float]) -> [Float] {
        carry.append(contentsOf: input)
        let groups = carry.count / 3
        guard groups > 0 else { return [] }
        var out = [Float](repeating: 0, count: groups)
        for index in 0..<groups {
            out[index] = (carry[index * 3] + carry[index * 3 + 1] + carry[index * 3 + 2]) / 3
        }
        carry.removeFirst(groups * 3)
        return out
    }
}

public enum SignalLevel {
    public static func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    public static func rms(_ samples: [Float]) -> Float { rms(samples[...]) }

    public static func normalized(rms: Float, floorDecibels: Float = -60) -> Float {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels - floorDecibels) / -floorDecibels))
    }
}

public struct StreamJob: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case partial, final }

    public var channel: AudioChannel
    public var kind: Kind
    public var startSample: Int
    public var samples: [Float]

    public var startSeconds: Double { Double(startSample) / Double(SpeechAudio.sampleRate) }
}

public struct ChannelStreamerConfig: Equatable, Sendable {
    public var windowSeconds: Double
    public var overlapSeconds: Double
    public var partialIntervalSeconds: Double
    public var emitsPartials: Bool
    public var silenceRMS: Float
    public var minimumFlushSeconds: Double

    public init(
        windowSeconds: Double = 5, overlapSeconds: Double = 1, partialIntervalSeconds: Double = 1.5,
        emitsPartials: Bool = true, silenceRMS: Float = 0.003, minimumFlushSeconds: Double = 0.6
    ) {
        self.windowSeconds = windowSeconds
        self.overlapSeconds = overlapSeconds
        self.partialIntervalSeconds = partialIntervalSeconds
        self.emitsPartials = emitsPartials
        self.silenceRMS = silenceRMS
        self.minimumFlushSeconds = minimumFlushSeconds
    }

    public static let live = ChannelStreamerConfig()
    public static let finalPass = ChannelStreamerConfig(windowSeconds: 30, overlapSeconds: 2, emitsPartials: false)
}

public struct ChannelStreamer: Sendable {
    public let channel: AudioChannel
    private let config: ChannelStreamerConfig
    private var buffer: [Float] = []
    private var bufferStart = 0
    private var windowStart = 0
    private var lastPartialEnd = 0
    private var total = 0

    public init(channel: AudioChannel, config: ChannelStreamerConfig = .live) {
        self.channel = channel
        self.config = config
    }

    private var rate: Double { Double(SpeechAudio.sampleRate) }
    private var windowSamples: Int { Int(config.windowSeconds * rate) }
    private var strideSamples: Int { max(1, Int((config.windowSeconds - config.overlapSeconds) * rate)) }
    private var partialSamples: Int { max(1, Int(config.partialIntervalSeconds * rate)) }
    public var totalSamples: Int { total }

    public mutating func append(_ samples: [Float]) -> [StreamJob] {
        buffer.append(contentsOf: samples)
        total += samples.count
        var jobs: [StreamJob] = []
        while total - windowStart >= windowSamples {
            let end = windowStart + windowSamples
            if let job = job(.final, from: windowStart, to: end) { jobs.append(job) }
            windowStart += strideSamples
            lastPartialEnd = windowStart
        }
        if config.emitsPartials, total - lastPartialEnd >= partialSamples, total - windowStart >= partialSamples {
            lastPartialEnd = total
            if let job = job(.partial, from: windowStart, to: total) { jobs.append(job) }
        }
        trim()
        return jobs
    }

    public mutating func flush() -> [StreamJob] {
        defer {
            windowStart = total
            lastPartialEnd = total
            trim()
        }
        let remaining = total - windowStart
        let coveredByLastWindow = windowStart > 0 && Double(remaining) <= config.overlapSeconds * rate
        guard Double(remaining) >= config.minimumFlushSeconds * rate, !coveredByLastWindow else { return [] }
        return job(.final, from: windowStart, to: total).map { [$0] } ?? []
    }

    public mutating func skipGap(samples: Int) -> [StreamJob] {
        let jobs = flush()
        total += samples
        windowStart = total
        lastPartialEnd = total
        bufferStart = total
        buffer = []
        return jobs
    }

    private func job(_ kind: StreamJob.Kind, from start: Int, to end: Int) -> StreamJob? {
        let lower = max(start, bufferStart) - bufferStart
        let upper = end - bufferStart
        guard lower < upper, upper <= buffer.count else { return nil }
        let slice = Array(buffer[lower..<upper])
        let first = max(start, bufferStart)
        guard SignalLevel.rms(slice) >= config.silenceRMS else {
            return kind == .final ? StreamJob(channel: channel, kind: .final, startSample: first, samples: []) : nil
        }
        return StreamJob(channel: channel, kind: kind, startSample: first, samples: slice)
    }

    private mutating func trim() {
        let drop = windowStart - bufferStart
        guard drop > 0 else { return }
        buffer.removeFirst(min(drop, buffer.count))
        bufferStart += drop
    }
}
