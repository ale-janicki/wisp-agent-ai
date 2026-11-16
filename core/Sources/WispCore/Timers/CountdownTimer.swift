import Foundation

public struct CountdownTimer: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let duration: Int
    public private(set) var endDate: Date?
    public private(set) var pausedRemaining: TimeInterval?

    public init(id: UUID = UUID(), duration: Int, startedAt: Date) {
        self.id = id
        self.duration = duration
        endDate = startedAt.addingTimeInterval(TimeInterval(duration))
        pausedRemaining = nil
    }

    public var isRunning: Bool { endDate != nil }

    public func remaining(at now: Date) -> TimeInterval {
        if let endDate { return max(0, endDate.timeIntervalSince(now)) }
        return max(0, pausedRemaining ?? 0)
    }

    public func fractionLeft(at now: Date) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, remaining(at: now) / TimeInterval(duration))
    }

    public func isFinished(at now: Date) -> Bool {
        guard let endDate else { return false }
        return endDate <= now
    }

    public mutating func pause(at now: Date) {
        guard isRunning else { return }
        pausedRemaining = remaining(at: now)
        endDate = nil
    }

    public mutating func resume(at now: Date) {
        guard let pausedRemaining else { return }
        endDate = now.addingTimeInterval(pausedRemaining)
        self.pausedRemaining = nil
    }

    public var label: String {
        if duration % 60 == 0 { return "Timer \(duration / 60) min" }
        return "Timer \(TimerFormat.clock(TimeInterval(duration)))"
    }
}

public struct TimerList: Codable, Equatable, Sendable {
    public private(set) var timers: [CountdownTimer]

    public init(timers: [CountdownTimer] = []) {
        self.timers = timers
    }

    @discardableResult
    public mutating func start(duration: Int, at now: Date) -> CountdownTimer {
        let timer = CountdownTimer(duration: duration, startedAt: now)
        timers.append(timer)
        return timer
    }

    public mutating func pause(_ id: UUID, at now: Date) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        timers[index].pause(at: now)
    }

    public mutating func resume(_ id: UUID, at now: Date) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        timers[index].resume(at: now)
    }

    public mutating func cancel(_ id: UUID) {
        timers.removeAll { $0.id == id }
    }

    public mutating func popFinished(at now: Date) -> [CountdownTimer] {
        let finished = timers.filter { $0.isFinished(at: now) }
        timers.removeAll { $0.isFinished(at: now) }
        return finished.sorted { ($0.endDate ?? now) < ($1.endDate ?? now) }
    }

    public var nextEnd: Date? {
        timers.compactMap(\.endDate).min()
    }

    public var soonest: CountdownTimer? {
        timers.filter(\.isRunning).min { ($0.endDate ?? .distantFuture) < ($1.endDate ?? .distantFuture) }
    }

    public static func announcement(for finished: [CountdownTimer]) -> String? {
        switch finished.count {
        case 0: nil
        case 1: "\(finished[0].label) acabou"
        default: "\(finished.count) timers acabaram"
        }
    }
}

public enum TimerFormat {
    public static let maxSeconds = 99 * 60 + 59

    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.up))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    public static func parse(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.count <= 2 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let minutes = Int(parts[0]) else { return nil }
        let seconds = parts.count == 2 ? Int(parts[1]) ?? 60 : 0
        guard seconds < 60 else { return nil }
        let total = minutes * 60 + seconds
        guard total > 0, total <= maxSeconds else { return nil }
        return total
    }
}
