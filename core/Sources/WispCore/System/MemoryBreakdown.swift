import Foundation

public struct VMPageCounts: Equatable, Sendable {
    public var pageSize: UInt64
    public var free: UInt64
    public var active: UInt64
    public var inactive: UInt64
    public var speculative: UInt64
    public var wired: UInt64
    public var compressor: UInt64
    public var purgeable: UInt64
    public var external: UInt64
    public var internalPages: UInt64

    public init(pageSize: UInt64, free: UInt64, active: UInt64, inactive: UInt64, speculative: UInt64,
                wired: UInt64, compressor: UInt64, purgeable: UInt64, external: UInt64, internalPages: UInt64) {
        self.pageSize = pageSize
        self.free = free
        self.active = active
        self.inactive = inactive
        self.speculative = speculative
        self.wired = wired
        self.compressor = compressor
        self.purgeable = purgeable
        self.external = external
        self.internalPages = internalPages
    }
}

public struct MemoryBreakdown: Equatable, Sendable {
    public var total: UInt64
    public var app: UInt64
    public var wired: UInt64
    public var compressed: UInt64
    public var cached: UInt64

    public var used: UInt64 { app + wired + compressed }
    public var usedFraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }

    public init(total: UInt64, app: UInt64, wired: UInt64, compressed: UInt64, cached: UInt64) {
        self.total = total
        self.app = app
        self.wired = wired
        self.compressed = compressed
        self.cached = cached
    }

    public init(counts: VMPageCounts, total: UInt64) {
        let page = counts.pageSize
        let appPages = counts.internalPages > counts.purgeable ? counts.internalPages - counts.purgeable : 0
        self.init(
            total: total,
            app: appPages * page,
            wired: counts.wired * page,
            compressed: counts.compressor * page,
            cached: (counts.external + counts.purgeable) * page
        )
    }
}

public enum MemoryPressure: Equatable, Sendable {
    case normal, warning, critical

    public init?(level: Int32) {
        switch level {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: return nil
        }
    }

    public var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Alerta"
        case .critical: "Crítica"
        }
    }
}
