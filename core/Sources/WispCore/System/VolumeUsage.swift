import Foundation

public struct VolumeUsage: Identifiable, Equatable, Sendable {
    public var name: String
    public var path: String
    public var total: UInt64
    public var available: UInt64
    public var availableRaw: UInt64
    public var isBoot: Bool

    public var id: String { path }

    public init(name: String, path: String, total: UInt64, available: UInt64, availableRaw: UInt64, isBoot: Bool) {
        self.name = name
        self.path = path
        self.total = total
        self.available = available
        self.availableRaw = availableRaw
        self.isBoot = isBoot
    }

    public var usedFraction: Double {
        guard total > 0 else { return 0 }
        return Double(total - min(total, available)) / Double(total)
    }

    public static func ordered(_ volumes: [VolumeUsage]) -> [VolumeUsage] {
        var seen = Set<String>()
        return volumes
            .filter { seen.insert($0.path).inserted }
            .sorted { ($0.isBoot ? 0 : 1, $0.name) < ($1.isBoot ? 0 : 1, $1.name) }
    }
}
