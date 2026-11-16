import Foundation

public struct SampleHistory: Equatable, Sendable {
    public private(set) var values: [Double] = []
    public let capacity: Int

    public init(capacity: Int = 30) {
        self.capacity = max(1, capacity)
    }

    public mutating func append(_ value: Double) {
        values.append(value.isFinite ? value : 0)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    public func normalized(floor: Double = 0) -> [Double] {
        let peak = max(floor, values.max() ?? 0)
        guard peak > 0 else { return values.map { _ in 0 } }
        return values.map { min(1, max(0, $0 / peak)) }
    }
}
