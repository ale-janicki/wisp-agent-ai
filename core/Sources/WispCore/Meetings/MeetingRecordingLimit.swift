import Foundation

public enum RecordingLimitEvent: Equatable, Sendable {
    case warning(remaining: Double)
    case reached
}

public struct RecordingLimitClock: Equatable, Sendable {
    public static let warningLead = 300.0

    public let limit: Double
    private var startedAt: Double?
    private var pausedTotal = 0.0
    private var pausedSince: Double?
    private var warned = false
    private var reached = false

    public init(limit: Double) {
        self.limit = limit
    }

    public mutating func start(at now: Double) {
        startedAt = now
    }

    public mutating func pause(at now: Double) {
        if pausedSince == nil { pausedSince = now }
    }

    public mutating func resume(at now: Double) {
        guard let since = pausedSince else { return }
        pausedTotal += max(0, now - since)
        pausedSince = nil
    }

    public func active(at now: Double) -> Double {
        guard let startedAt else { return 0 }
        let ongoing = pausedSince.map { max(0, now - $0) } ?? 0
        return max(0, now - startedAt - pausedTotal - ongoing)
    }

    public func remaining(at now: Double) -> Double { max(0, limit - active(at: now)) }

    public mutating func tick(at now: Double) -> RecordingLimitEvent? {
        guard limit > 0, !reached else { return nil }
        let left = remaining(at: now)
        if left <= 0 {
            reached = true
            return .reached
        }
        if !warned, limit > Self.warningLead, left <= Self.warningLead {
            warned = true
            return .warning(remaining: left)
        }
        return nil
    }
}
