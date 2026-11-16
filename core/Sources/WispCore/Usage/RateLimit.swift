import Foundation

public struct RateLimitWindow: Equatable, Sendable {
    public var utilization: Double
    public var resetsAt: Date?

    public init(utilization: Double, resetsAt: Date? = nil) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

public struct RateLimit: Equatable, Sendable {
    public var fiveHour: RateLimitWindow?
    public var sevenDay: RateLimitWindow?

    public init(fiveHour: RateLimitWindow? = nil, sevenDay: RateLimitWindow? = nil) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    public init(info: [String: Any]?) {
        let windows = info?["unifiedWindows"] as? [String: Any]
        self.init(
            fiveHour: Self.window(windows?["five_hour"]),
            sevenDay: Self.window(windows?["seven_day"])
        )
    }

    private static func window(_ raw: Any?) -> RateLimitWindow? {
        guard let object = raw as? [String: Any],
              let utilization = (object["utilization"] as? NSNumber)?.doubleValue
        else { return nil }
        let resets = (object["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return RateLimitWindow(utilization: utilization, resetsAt: resets)
    }
}
