import Foundation

public struct AlignedChunk: Equatable, Sendable {
    public var samples: [Float]
    public var gapSeconds: Double?
}

public final class LiveAudioAligner: @unchecked Sendable {
    public static let toleranceFrames = 1_200
    public static let maxFillSeconds = 2.0

    private let lock = NSLock()
    private var origin: Double?
    private var ends: [AudioChannel: Int] = [:]

    public init() {}

    public func align(_ samples: [Float], channel: AudioChannel, at time: Double) -> AlignedChunk {
        lock.withLock {
            let base = origin ?? time
            origin = base
            let rate = Double(CaptureFormat.sampleRate)
            let cap = Int(Self.maxFillSeconds * rate)
            let start = Int(((time - base) * rate).rounded())
            let end = ends[channel] ?? 0
            let firstChunk = ends[channel] == nil
            if start < 0 {
                let kept = Array(samples.dropFirst(-start))
                ends[channel] = kept.count
                return AlignedChunk(samples: kept, gapSeconds: nil)
            }
            if start > end + (firstChunk ? 0 : Self.toleranceFrames) {
                let gap = start - end
                ends[channel] = start + samples.count
                if gap > cap { return AlignedChunk(samples: samples, gapSeconds: Double(gap) / rate) }
                return AlignedChunk(samples: [Float](repeating: 0, count: gap) + samples, gapSeconds: nil)
            }
            if start < end - Self.toleranceFrames {
                let kept = Array(samples.dropFirst(end - start))
                ends[channel] = end + kept.count
                return AlignedChunk(samples: kept, gapSeconds: nil)
            }
            ends[channel] = end + samples.count
            return AlignedChunk(samples: samples, gapSeconds: nil)
        }
    }
}
