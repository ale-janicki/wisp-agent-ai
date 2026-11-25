import Foundation
import os

enum TerminalPerf {
    struct Counters: Equatable {
        var readNs: UInt64 = 0
        var reads = 0
        var captureNs: UInt64 = 0
        var captures = 0
        var liveNs: UInt64 = 0
        var liveTicks = 0
        var tickNs: UInt64 = 0
        var ticks = 0
    }

    private static let state = OSAllocatedUnfairLock(initialState: Counters())

    static var counters: Counters { state.withLock { $0 } }

    static func reset() { state.withLock { $0 = Counters() } }

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    static func record(_ change: @Sendable (inout Counters) -> Void) { state.withLock { change(&$0) } }
}
