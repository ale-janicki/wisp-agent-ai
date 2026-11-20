import Foundation

public enum MonoDownmix {
    public static func interleaved(_ samples: UnsafeBufferPointer<Float>, channels: Int) -> [Float] {
        guard channels > 0 else { return [] }
        if channels == 1 { return Array(samples) }
        let frames = samples.count / channels
        var out = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += samples[frame * channels + channel] }
            out[frame] = sum * scale
        }
        return out
    }

    public static func planar(_ planes: [UnsafeBufferPointer<Float>]) -> [Float] {
        guard let frames = planes.map(\.count).min(), !planes.isEmpty else { return [] }
        var out = [Float](repeating: 0, count: frames)
        let scale = 1 / Float(planes.count)
        for frame in 0..<frames {
            var sum: Float = 0
            for plane in planes { sum += plane[frame] }
            out[frame] = sum * scale
        }
        return out
    }
}

public struct LinearResampler: Sendable {
    private let step: Double
    private let isIdentity: Bool
    private var buffer: [Float] = []
    private var position: Double = 0

    public init(from inputRate: Double, to outputRate: Double = Double(CaptureFormat.sampleRate)) {
        isIdentity = inputRate == outputRate || inputRate <= 0 || outputRate <= 0
        step = isIdentity ? 1 : inputRate / outputRate
    }

    public mutating func process(_ input: [Float]) -> [Float] {
        if isIdentity { return input }
        buffer.append(contentsOf: input)
        var out: [Float] = []
        out.reserveCapacity(Int(Double(input.count) / step) + 1)
        while Int(position) + 1 < buffer.count {
            let index = Int(position)
            let fraction = Float(position - Double(index))
            out.append(buffer[index] + (buffer[index + 1] - buffer[index]) * fraction)
            position += step
        }
        let consumed = min(Int(position), buffer.count)
        buffer.removeFirst(consumed)
        position -= Double(consumed)
        return out
    }
}
