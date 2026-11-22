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
    public enum Kind: Equatable, Sendable { case typing, final, noise }

    public var channel: AudioChannel
    public var kind: Kind
    public var startSample: Int
    public var samples: [Float]
    public var endSample: Int?

    public var startSeconds: Double { Double(startSample) / Double(SpeechAudio.sampleRate) }

    public var endSeconds: Double { Double(endSample ?? startSample) / Double(SpeechAudio.sampleRate) }
}

public typealias ChannelStreamerConfig = SpeechSegmenterConfig

public struct ChannelStreamer: Sendable {
    public let channel: AudioChannel
    private var segmenter: SpeechSegmenter

    public init(channel: AudioChannel, config: ChannelStreamerConfig = .default) {
        self.channel = channel
        segmenter = SpeechSegmenter(config: config)
    }

    public var totalSamples: Int { segmenter.totalSamples }

    public mutating func append(_ samples: [Float]) -> [StreamJob] { jobs(segmenter.append(samples)) }

    public mutating func flush() -> [StreamJob] { jobs(segmenter.flush()) }

    public mutating func skipGap(samples: Int) -> [StreamJob] { jobs(segmenter.skipGap(samples: samples)) }

    private func jobs(_ events: [SegmenterEvent]) -> [StreamJob] {
        events.map { event in
            switch event {
            case .opened(let start): StreamJob(channel: channel, kind: .typing, startSample: start, samples: [])
            case .segment(let start, let samples): StreamJob(channel: channel, kind: .final, startSample: start, samples: samples)
            case .dropped: StreamJob(channel: channel, kind: .final, startSample: 0, samples: [])
            case .noise(let start, let end): StreamJob(channel: channel, kind: .noise, startSample: start, samples: [], endSample: end)
            }
        }
    }
}
