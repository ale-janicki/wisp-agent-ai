import Foundation

public struct InterfaceCounters: Equatable, Sendable {
    public var received: UInt32
    public var sent: UInt32

    public init(received: UInt32, sent: UInt32) {
        self.received = received
        self.sent = sent
    }
}

public struct NetworkRate: Equatable, Sendable {
    public var down: UInt64
    public var up: UInt64

    public init(down: UInt64, up: UInt64) {
        self.down = down
        self.up = up
    }

    public static func between(_ previous: InterfaceCounters, _ current: InterfaceCounters, seconds: TimeInterval) -> NetworkRate? {
        guard seconds > 0 else { return nil }
        let down = Double(current.received &- previous.received) / seconds
        let up = Double(current.sent &- previous.sent) / seconds
        return NetworkRate(down: UInt64(down.rounded()), up: UInt64(up.rounded()))
    }
}
