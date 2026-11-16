import Foundation

public struct UsageBlock: Codable, Sendable, Equatable {
    public var limits: String?

    public init(limits: String? = nil) {
        self.limits = limits
    }
}

public enum PlanLimitSeverity: Equatable, Sendable {
    case normal, warning, critical

    public init(utilization: Double) {
        self = utilization >= 0.9 ? .critical : utilization >= 0.75 ? .warning : .normal
    }
}

public struct PlanLimitRow: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case session, week }
    public enum State: Equatable, Sendable {
        case used(percent: Int, resetsAt: Date?, severity: PlanLimitSeverity)
        case renewed
    }

    public var kind: Kind
    public var state: State
}

public struct PlanLimitsSnapshot: Equatable, Sendable {
    public var limit: RateLimit
    public var capturedAt: Date

    public init(limit: RateLimit, capturedAt: Date) {
        self.limit = limit
        self.capturedAt = capturedAt
    }

    public init?(json: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any],
              let captured = (object["captured_at"] as? NSNumber)?.doubleValue
        else { return nil }
        let limit = RateLimit(
            fiveHour: Self.window(object["five_hour"]),
            sevenDay: Self.window(object["seven_day"])
        )
        guard limit.fiveHour != nil || limit.sevenDay != nil else { return nil }
        self.init(limit: limit, capturedAt: Date(timeIntervalSince1970: captured))
    }

    public static func read(path: String) -> PlanLimitsSnapshot? {
        guard let data = FileManager.default.contents(atPath: expandTilde(path)) else { return nil }
        return PlanLimitsSnapshot(json: data)
    }

    public static func newest(_ a: PlanLimitsSnapshot?, _ b: PlanLimitsSnapshot?) -> PlanLimitsSnapshot? {
        guard let a else { return b }
        guard let b else { return a }
        return b.capturedAt > a.capturedAt ? b : a
    }

    public func rows(now: Date) -> [PlanLimitRow] {
        [(PlanLimitRow.Kind.session, limit.fiveHour), (.week, limit.sevenDay)].compactMap { kind, window in
            guard let window else { return nil }
            if let resetsAt = window.resetsAt, resetsAt <= now {
                return PlanLimitRow(kind: kind, state: .renewed)
            }
            return PlanLimitRow(kind: kind, state: .used(
                percent: Int((window.utilization * 100).rounded()),
                resetsAt: window.resetsAt,
                severity: PlanLimitSeverity(utilization: window.utilization)
            ))
        }
    }

    public static func age(of date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "atualizado agora" }
        if seconds < 3600 { return "atualizado há \(Int(seconds / 60)) min" }
        if seconds < 86_400 { return "atualizado há \(Int(seconds / 3600)) h" }
        return "atualizado há \(Int(seconds / 86_400)) d"
    }

    private static func window(_ raw: Any?) -> RateLimitWindow? {
        guard let object = raw as? [String: Any],
              let percentage = (object["used_percentage"] as? NSNumber)?.doubleValue
        else { return nil }
        let resets = (object["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return RateLimitWindow(utilization: percentage / 100, resetsAt: resets)
    }
}
