import Foundation

/// Thresholds for deciding that a mic speech segment is the speakers' output leaking back into the mic.
public struct BleedConfig: Equatable, Sendable {
    /// Energy frame length for the envelope comparison (25 ms at 16 kHz).
    public var frameSamples: Int
    /// Largest delay between the system channel and its copy on the mic that is searched, in either direction.
    public var maxLagSeconds: Double
    /// A mic frame at or above this RMS counts as mic speech.
    public var micActiveRMS: Float
    /// A system frame at or above this RMS counts as system speech.
    public var systemActiveRMS: Float
    /// Share of mic speech frames that must coincide with system speech.
    public var minOverlap: Double
    /// Normalized cross-correlation of the two envelopes, at the best lag, needed to call it a copy.
    public var minCorrelation: Float
    /// The mic must be quieter than the system by this ratio. Real double talk has the mic louder, so it stays above it.
    public var maxLevelRatio: Float
    /// Segments with fewer frames than this are never judged: independent short interjections ("sim", "uhum") reach the
    /// correlation threshold by chance too often.
    public var minFrames: Int
    /// Segments shorter than this many frames need `shortMinCorrelation` instead of `minCorrelation`.
    public var shortSegmentFrames: Int
    /// Correlation needed by a segment shorter than `shortSegmentFrames`.
    public var shortMinCorrelation: Float
    /// How much system audio the transcribers keep to compare against.
    public var historySeconds: Double

    public init(
        frameSamples: Int = 400, maxLagSeconds: Double = 0.15, micActiveRMS: Float = 0.002, systemActiveRMS: Float = 0.002,
        minOverlap: Double = 0.6, minCorrelation: Float = 0.7, maxLevelRatio: Float = 0.7, minFrames: Int = 40,
        shortSegmentFrames: Int = 80, shortMinCorrelation: Float = 0.85, historySeconds: Double = 90
    ) {
        self.frameSamples = frameSamples
        self.maxLagSeconds = maxLagSeconds
        self.micActiveRMS = micActiveRMS
        self.systemActiveRMS = systemActiveRMS
        self.minOverlap = minOverlap
        self.minCorrelation = minCorrelation
        self.maxLevelRatio = maxLevelRatio
        self.minFrames = minFrames
        self.shortSegmentFrames = shortSegmentFrames
        self.shortMinCorrelation = shortMinCorrelation
        self.historySeconds = historySeconds
    }

    public static let `default` = BleedConfig()

    public var maxLagFrames: Int { max(1, Int((maxLagSeconds * Double(SpeechAudio.sampleRate) / Double(frameSamples)).rounded())) }

    /// Samples of system audio needed on each side of the mic segment.
    public var padSamples: Int { maxLagFrames * frameSamples }

    /// Correlation a segment of `frames` envelope frames must reach to be called a copy.
    public func requiredCorrelation(frames: Int) -> Float {
        frames < shortSegmentFrames ? max(minCorrelation, shortMinCorrelation) : minCorrelation
    }
}

/// Rolling copy of one channel's 16 kHz audio, indexed by the same absolute sample count the segmenter uses.
/// A fixed ring: pushing never moves the kept samples, and reading copies only the requested window.
public struct ChannelHistory: Sendable {
    private var ring: [Float] = []
    private let capacity: Int
    /// Absolute index of the oldest kept sample; above zero once audio was dropped or skipped.
    private var start = 0
    public private(set) var end = 0

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    public mutating func append(_ new: [Float]) {
        guard !new.isEmpty else { return }
        if ring.isEmpty { ring = [Float](repeating: 0, count: capacity) }
        let kept = new.suffix(capacity)
        var write = (end + new.count - kept.count) % capacity
        var index = kept.startIndex
        while index < kept.endIndex {
            let run = min(capacity - write, kept.endIndex - index)
            ring.replaceSubrange(write..<(write + run), with: kept[index..<(index + run)])
            index += run
            write = (write + run) % capacity
        }
        end += new.count
        start = max(start, end - capacity)
    }

    public mutating func skip(_ count: Int) {
        end += max(0, count)
        start = end
    }

    /// Samples in `from..<to`. Before the first sample ever recorded and after the newest one is zero (silence);
    /// nil when the range falls in audio that was already dropped or skipped, so the caller cannot judge.
    public func window(from: Int, to: Int) -> [Float]? {
        guard to > from else { return [] }
        if from < start, start > 0 { return nil }
        var out = [Float](repeating: 0, count: to - from)
        var lower = max(from, start)
        let upper = min(to, end)
        while lower < upper {
            let read = lower % capacity
            let run = min(capacity - read, upper - lower)
            out.replaceSubrange((lower - from)..<(lower - from + run), with: ring[read..<(read + run)])
            lower += run
        }
        return out
    }
}

public enum BleedDetector {
    /// Judges a mic segment against the system history. Unknown history keeps the segment.
    public static func isBleed(
        mic: [Float], micStart: Int, system: ChannelHistory, config: BleedConfig = .default
    ) -> Bool {
        guard let window = systemWindow(micStart: micStart, micCount: mic.count, system: system, config: config) else { return false }
        return isBleed(mic: mic, systemWindow: window, config: config)
    }

    /// The system audio a mic segment is compared against, or nil when the segment is too short to judge or the
    /// history no longer (or never) covers it. Cheap to call under a lock: it copies only this window.
    public static func systemWindow(micStart: Int, micCount: Int, system: ChannelHistory, config: BleedConfig = .default) -> [Float]? {
        let pad = config.padSamples
        guard micCount >= config.minFrames * config.frameSamples else { return nil }
        return system.window(from: micStart - pad, to: micStart + micCount + pad)
    }

    /// `systemWindow` starts `config.padSamples` before the first mic sample and ends that many after the last.
    public static func isBleed(mic: [Float], systemWindow: [Float], config: BleedConfig = .default) -> Bool {
        let frame = config.frameSamples
        let lagFrames = config.maxLagFrames
        let micFrames = mic.count / frame
        guard micFrames >= config.minFrames, systemWindow.count >= (micFrames + 2 * lagFrames) * frame else { return false }
        let m = envelope(mic, frames: micFrames, frame: frame)
        let s = envelope(systemWindow, frames: micFrames + 2 * lagFrames, frame: frame)
        guard m.contains(where: { $0 >= config.micActiveRMS }), s.contains(where: { $0 >= config.systemActiveRMS }) else { return false }

        var bestLag = 0
        var best: Float = -1
        for lag in -lagFrames...lagFrames {
            let value = correlation(m, s, offset: lagFrames + lag)
            if value > best {
                best = value
                bestLag = lag
            }
        }
        guard best >= config.requiredCorrelation(frames: micFrames) else { return false }

        var active = 0
        var overlapping = 0
        var micEnergy: Float = 0
        var systemEnergy: Float = 0
        for index in 0..<micFrames where m[index] >= config.micActiveRMS {
            let other = s[index + lagFrames + bestLag]
            active += 1
            if other >= config.systemActiveRMS { overlapping += 1 }
            micEnergy += m[index] * m[index]
            systemEnergy += other * other
        }
        guard active > 0, Double(overlapping) / Double(active) >= config.minOverlap else { return false }
        return micEnergy.squareRoot() < systemEnergy.squareRoot() * config.maxLevelRatio
    }

    private static func envelope(_ samples: [Float], frames: Int, frame: Int) -> [Float] {
        (0..<frames).map { SignalLevel.rms(samples[($0 * frame)..<(($0 + 1) * frame)]) }
    }

    /// Pearson correlation of `a` against the slice of `b` starting at `offset`.
    private static func correlation(_ a: [Float], _ b: [Float], offset: Int) -> Float {
        let count = a.count
        var meanA: Float = 0
        var meanB: Float = 0
        for index in 0..<count {
            meanA += a[index]
            meanB += b[index + offset]
        }
        meanA /= Float(count)
        meanB /= Float(count)
        var cross: Float = 0
        var varA: Float = 0
        var varB: Float = 0
        for index in 0..<count {
            let x = a[index] - meanA
            let y = b[index + offset] - meanB
            cross += x * y
            varA += x * x
            varB += y * y
        }
        let denominator = (varA * varB).squareRoot()
        return denominator > 1e-12 ? cross / denominator : 0
    }
}
