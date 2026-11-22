import Foundation

public struct RecurrenceForm: Equatable, Sendable {
    public enum EndMode: Hashable, Sendable { case never, count, until }

    public var original: CalRecurrence?
    public var frequency: RecurrenceFrequency?
    public var interval: Int
    public var endMode: EndMode
    public var endCount: Int
    public var endUntil: Date
    public private(set) var touched = false

    public init(original: CalRecurrence?, fallbackUntil: Date = Date()) {
        self.original = original
        frequency = original?.frequency
        interval = original?.interval ?? 1
        endCount = 5
        endUntil = fallbackUntil
        switch original?.end {
        case .count(let count)?:
            endMode = .count
            endCount = count
        case .until(let date)?:
            endMode = .until
            endUntil = date
        default:
            endMode = .never
        }
    }

    public mutating func edit(_ change: (inout RecurrenceForm) -> Void) {
        change(&self)
        touched = true
    }

    public var resolved: CalRecurrence? {
        guard touched else { return original }
        guard let frequency else { return nil }
        let end: RecurrenceEnd = switch endMode {
        case .never: .never
        case .count: .count(max(1, endCount))
        case .until: .until(endUntil)
        }
        return (original ?? CalRecurrence(frequency: frequency)).changing(frequency: frequency, interval: interval, end: end)
    }

    public func change() -> RecurrenceChange {
        guard touched, resolved != original else { return .keep }
        return resolved.map(RecurrenceChange.set) ?? .remove
    }
}
