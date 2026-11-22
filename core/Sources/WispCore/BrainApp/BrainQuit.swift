import Foundation

public enum QuitDeadline {
    public static let flushSeconds: Double = 3
    public static let willTerminateMarginSeconds: Double = 5
    public static var flushTimeout: Duration { .seconds(flushSeconds) }
    public static var sigtermFallbackSeconds: Double { flushSeconds + willTerminateMarginSeconds }
}

@MainActor
public final class BrainQuitRegistration {
    private let quit: QuitFlush
    private let flusher: @MainActor () -> Void
    private var token: UUID?

    public init(quit: QuitFlush = .shared, flusher: @escaping @MainActor () -> Void) {
        self.quit = quit
        self.flusher = flusher
    }

    public var isRegistered: Bool { token != nil }

    public func update(hasOpenNotes: Bool) {
        if hasOpenNotes, token == nil {
            token = quit.register { [flusher] in flusher() }
        } else if !hasOpenNotes, let current = token {
            quit.unregister(current)
            token = nil
        }
    }
}

public struct BrainRecoveryLedger: Sendable {
    private var copied: [String: String] = [:]

    public init() {}

    public mutating func shouldCopy(_ key: String, text: String) -> Bool {
        guard copied[key] != text else { return false }
        copied[key] = text
        return true
    }

    public mutating func forget(_ key: String) {
        copied[key] = nil
    }
}
