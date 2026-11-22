import Foundation

@MainActor
public final class QuitFlush {
    public typealias Flusher = @MainActor () async -> Void

    public static let shared = QuitFlush()

    private var flushers: [UUID: Flusher] = [:]

    public init() {}

    public var isEmpty: Bool { flushers.isEmpty }

    @discardableResult
    public func register(_ flusher: @escaping Flusher) -> UUID {
        let id = UUID()
        flushers[id] = flusher
        return id
    }

    public func unregister(_ id: UUID) {
        flushers[id] = nil
    }

    public func flushAll(timeout: Duration = .seconds(3)) async {
        let pending = Array(flushers.values)
        guard !pending.isEmpty else { return }
        let latch = Latch(remaining: pending.count)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            latch.continuation = continuation
            for flusher in pending {
                Task { @MainActor in
                    await flusher()
                    latch.oneDone()
                }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                latch.finish()
            }
        }
    }

    @MainActor
    private final class Latch {
        var remaining: Int
        var continuation: CheckedContinuation<Void, Never>?

        init(remaining: Int) {
            self.remaining = remaining
        }

        func oneDone() {
            remaining -= 1
            if remaining == 0 { finish() }
        }

        func finish() {
            continuation?.resume()
            continuation = nil
        }
    }
}

public enum DrawingCloseWait {
    public static func until(timeout: Duration, poll: Duration = .milliseconds(50), done: @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await MainActor.run(body: done) { return }
            try? await Task.sleep(for: poll)
        }
    }
}

@MainActor
public final class DrawingClosingTracker {
    public private(set) var isClosing = false
    public private(set) var isFinished = false

    public init() {}

    public func begin() {
        isClosing = true
    }

    public func finish() {
        isClosing = true
        isFinished = true
    }

    public func waitUntilFinished(timeout: Duration = .seconds(3)) async {
        await DrawingCloseWait.until(timeout: timeout) { self.isFinished }
    }
}
