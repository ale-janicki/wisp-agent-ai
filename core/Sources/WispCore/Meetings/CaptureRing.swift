import Foundation
import Synchronization

public struct RingSlot {
    public let samples: UnsafeBufferPointer<Float>
    public let channels: Int
    public let rate: Double
    public let time: Double
}

public final class CaptureRing: @unchecked Sendable {
    public static let maxChannels = 4

    private let slotFrames: Int
    private let slotCount: Int
    private let samples: UnsafeMutablePointer<Float>
    private let frameCounts: UnsafeMutablePointer<Int>
    private let channelCounts: UnsafeMutablePointer<Int>
    private let rates: UnsafeMutablePointer<Double>
    private let times: UnsafeMutablePointer<Double>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    private let overruns = Atomic<Int>(0)

    public init(slotFrames: Int = 4096, slotCount: Int = 48) {
        self.slotFrames = slotFrames
        self.slotCount = slotCount
        samples = .allocate(capacity: slotFrames * slotCount * Self.maxChannels)
        samples.initialize(repeating: 0, count: slotFrames * slotCount * Self.maxChannels)
        frameCounts = .allocate(capacity: slotCount)
        frameCounts.initialize(repeating: 0, count: slotCount)
        channelCounts = .allocate(capacity: slotCount)
        channelCounts.initialize(repeating: 0, count: slotCount)
        rates = .allocate(capacity: slotCount)
        rates.initialize(repeating: 0, count: slotCount)
        times = .allocate(capacity: slotCount)
        times.initialize(repeating: 0, count: slotCount)
    }

    deinit {
        samples.deallocate()
        frameCounts.deallocate()
        channelCounts.deallocate()
        rates.deallocate()
        times.deallocate()
    }

    public var overrunCount: Int { overruns.load(ordering: .relaxed) }

    public func push(planar planes: UnsafePointer<UnsafeMutablePointer<Float>>, channels: Int, frames: Int, rate: Double, time: Double) {
        write(channels: channels, frames: frames, rate: rate, time: time) { destination, offset, count, stored in
            for frame in 0..<count {
                for channel in 0..<stored { destination[frame * stored + channel] = planes[channel][offset + frame] }
            }
        }
    }

    public func push(interleaved: UnsafeBufferPointer<Float>, channels: Int, rate: Double, time: Double) {
        guard channels > 0 else { return }
        write(channels: channels, frames: interleaved.count / channels, rate: rate, time: time) { destination, offset, count, stored in
            for frame in 0..<count {
                for channel in 0..<stored { destination[frame * stored + channel] = interleaved[(offset + frame) * channels + channel] }
            }
        }
    }

    public func push(mono: [Float], rate: Double = Double(CaptureFormat.sampleRate), time: Double) {
        mono.withUnsafeBufferPointer { push(interleaved: $0, channels: 1, rate: rate, time: time) }
    }

    @discardableResult
    public func pop(_ body: (RingSlot) -> Void) -> Bool {
        let current = tail.load(ordering: .relaxed)
        guard current < head.load(ordering: .acquiring) else { return false }
        let slot = current % slotCount
        let start = samples + slot * slotFrames * Self.maxChannels
        body(RingSlot(
            samples: UnsafeBufferPointer(start: start, count: frameCounts[slot] * channelCounts[slot]),
            channels: channelCounts[slot], rate: rates[slot], time: times[slot]
        ))
        tail.store(current + 1, ordering: .releasing)
        return true
    }

    private func write(
        channels: Int, frames: Int, rate: Double, time: Double,
        copy: (UnsafeMutablePointer<Float>, Int, Int, Int) -> Void
    ) {
        guard frames > 0, channels > 0, rate > 0 else { return }
        let stored = min(channels, Self.maxChannels)
        var offset = 0
        while offset < frames {
            let current = head.load(ordering: .relaxed)
            guard current - tail.load(ordering: .acquiring) < slotCount else {
                overruns.wrappingAdd(1, ordering: .relaxed)
                return
            }
            let slot = current % slotCount
            let count = min(slotFrames, frames - offset)
            copy(samples + slot * slotFrames * Self.maxChannels, offset, count, stored)
            frameCounts[slot] = count
            channelCounts[slot] = stored
            rates[slot] = rate
            times[slot] = time + Double(offset) / rate
            head.store(current + 1, ordering: .releasing)
            offset += count
        }
    }
}
