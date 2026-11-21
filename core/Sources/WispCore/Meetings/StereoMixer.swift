import Foundation

public enum CaptureFormat {
    public static let sampleRate = 48_000
}

public struct StereoMixer: Sendable {
    private var mic: [Float] = []
    private var system: [Float] = []
    private var origin: Double?
    private var pendingMic: [(time: Double, samples: [Float])] = []
    private var pendingSystem: [(time: Double, samples: [Float])] = []
    private var emitted = 0
    private let maxSkewFrames: Int
    private let toleranceFrames: Int

    public init(maxSkewFrames: Int = CaptureFormat.sampleRate / 2, toleranceFrames: Int = CaptureFormat.sampleRate / 40) {
        self.maxSkewFrames = max(0, maxSkewFrames)
        self.toleranceFrames = max(0, toleranceFrames)
    }

    public mutating func push(mic samples: [Float], at time: Double) {
        guard origin != nil else {
            pendingMic.append((time, samples))
            resolveOriginIfReady(force: false)
            return
        }
        place(samples, at: time, mic: true)
    }

    public mutating func push(system samples: [Float], at time: Double) {
        guard origin != nil else {
            pendingSystem.append((time, samples))
            resolveOriginIfReady(force: false)
            return
        }
        place(samples, at: time, mic: false)
    }

    public mutating func pull(flush: Bool = false) -> [Float] {
        if origin == nil, flush { resolveOriginIfReady(force: true) }
        guard origin != nil else { return [] }
        let shorter = min(mic.count, system.count)
        let longer = max(mic.count, system.count)
        let frames = flush ? longer : max(shorter, longer - maxSkewFrames)
        guard frames > 0 else { return [] }
        var out = [Float](repeating: 0, count: frames * 2)
        for index in 0..<min(frames, mic.count) { out[index * 2] = mic[index] }
        for index in 0..<min(frames, system.count) { out[index * 2 + 1] = system[index] }
        mic.removeFirst(min(frames, mic.count))
        system.removeFirst(min(frames, system.count))
        emitted += frames
        return out
    }

    private mutating func resolveOriginIfReady(force: Bool) {
        let micFrames = pendingMic.reduce(0) { $0 + $1.samples.count }
        let systemFrames = pendingSystem.reduce(0) { $0 + $1.samples.count }
        let both = !pendingMic.isEmpty && !pendingSystem.isEmpty
        guard force || both || micFrames > maxSkewFrames || systemFrames > maxSkewFrames else { return }
        let firsts = [pendingMic.first?.time, pendingSystem.first?.time].compactMap { $0 }
        guard let earliest = firsts.min() else { return }
        origin = earliest
        for chunk in pendingMic { place(chunk.samples, at: chunk.time, mic: true) }
        for chunk in pendingSystem { place(chunk.samples, at: chunk.time, mic: false) }
        pendingMic = []
        pendingSystem = []
    }

    private mutating func place(_ samples: [Float], at time: Double, mic isMic: Bool) {
        let position = Int(((time - (origin ?? time)) * Double(CaptureFormat.sampleRate)).rounded())
        if isMic {
            Self.place(samples, position: position, emitted: emitted, tolerance: toleranceFrames, into: &mic)
        } else {
            Self.place(samples, position: position, emitted: emitted, tolerance: toleranceFrames, into: &system)
        }
    }

    private static func place(_ samples: [Float], position: Int, emitted: Int, tolerance: Int, into lane: inout [Float]) {
        var chunk = samples[...]
        var start = position
        if start < emitted {
            let cut = min(emitted - start, chunk.count)
            chunk = chunk.dropFirst(cut)
            start += cut
        }
        let end = emitted + lane.count
        if start > end + tolerance {
            lane.append(contentsOf: repeatElement(0, count: start - end))
        } else if start < end - tolerance {
            chunk = chunk.dropFirst(min(end - start, chunk.count))
        }
        lane.append(contentsOf: chunk)
    }
}
