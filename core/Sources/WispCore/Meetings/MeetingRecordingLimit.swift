import Foundation

public enum RecordingLimitEvent: Equatable, Sendable {
    case warning(remaining: Double)
    case reached
}

public struct RecordingLimitClock: Equatable, Sendable {
    public static let warningLead = 300.0
    public static let largestStep = 10.0

    public let limit: Double
    public private(set) var active = 0.0
    private var last: Double?
    private var warned = false
    private var reached = false

    public init(limit: Double) {
        self.limit = limit
    }

    public var remaining: Double { max(0, limit - active) }

    public mutating func start(at now: Double) {
        last = now
    }

    public mutating func tick(at now: Double, paused: Bool = false) -> RecordingLimitEvent? {
        defer { last = now }
        if let last, !paused, now > last, now - last <= Self.largestStep { active += now - last }
        guard limit > 0, !reached else { return nil }
        if active >= limit {
            reached = true
            return .reached
        }
        if !warned, limit > Self.warningLead, remaining <= Self.warningLead {
            warned = true
            return .warning(remaining: remaining)
        }
        return nil
    }
}
