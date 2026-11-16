import Foundation

public struct CPUTicks: Equatable, Sendable {
    public var user: UInt32
    public var system: UInt32
    public var idle: UInt32
    public var nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }
}

public enum CoreKind: String, Sendable {
    case efficiency = "E"
    case performance = "P"
}

public struct CPUUsage: Equatable, Sendable {
    public var total: Double
    public var efficiency: Double?
    public var performance: Double?

    public init(total: Double, efficiency: Double? = nil, performance: Double? = nil) {
        self.total = total
        self.efficiency = efficiency
        self.performance = performance
    }

    public static func between(_ previous: [CPUTicks], _ current: [CPUTicks], kinds: [CoreKind?] = []) -> CPUUsage? {
        guard previous.count == current.count, !current.isEmpty else { return nil }
        var busy: [CoreKind?: UInt64] = [:]
        var all: [CoreKind?: UInt64] = [:]
        for index in current.indices {
            let old = previous[index], new = current[index]
            let used = UInt64(new.user &- old.user) + UInt64(new.system &- old.system) + UInt64(new.nice &- old.nice)
            let span = used + UInt64(new.idle &- old.idle)
            let kind = kinds.indices.contains(index) ? kinds[index] : nil
            busy[kind, default: 0] += used
            all[kind, default: 0] += span
        }
        let totalSpan = all.values.reduce(0, +)
        guard totalSpan > 0 else { return nil }
        func fraction(_ kind: CoreKind) -> Double? {
            guard let span = all[kind], span > 0 else { return nil }
            return Double(busy[kind] ?? 0) / Double(span)
        }
        return CPUUsage(
            total: Double(busy.values.reduce(0, +)) / Double(totalSpan),
            efficiency: fraction(.efficiency),
            performance: fraction(.performance)
        )
    }
}
