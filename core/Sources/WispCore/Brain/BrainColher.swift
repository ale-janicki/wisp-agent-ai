import Foundation

public enum BrainColher {
    public static let arguments = ["brain", "colher", "--if-due", "--json"]
    public static let timeout: TimeInterval = 1800

    public struct Counts: Sendable, Equatable {
        public let harvested: Int
        public let skipped: Int
    }

    private struct Report: Decodable {
        let colhidas: [JSONSkip]
        let puladas: [JSONSkip]
    }

    private struct JSONSkip: Decodable {
        init(from decoder: Decoder) throws {}
    }

    public static func counts(from output: Data) -> Counts? {
        guard let report = try? JSONDecoder().decode(Report.self, from: output) else { return nil }
        return Counts(harvested: report.colhidas.count, skipped: report.puladas.count)
    }

    public static func environment(wisp: URL, base: [String: String], loginPATH: String?) -> [String: String] {
        var environment = RuntimeEnvironment.forRuntime(base)
        let runtimeRoot = wisp.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        environment["WISP_RESOURCES"] = runtimeRoot.appendingPathComponent("src").path
        if let loginPATH { environment["PATH"] = loginPATH }
        return environment
    }

    public static func run(wisp: URL, environment: [String: String]) async -> Counts? {
        let child = Child()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    guard let output = child.run(wisp: wisp, environment: environment), !output.timedOut else {
                        continuation.resume(returning: nil)
                        return
                    }
                    continuation.resume(returning: counts(from: output.stdout))
                }
            }
        } onCancel: {
            child.cancel()
        }
    }

    static let killGrace: TimeInterval = 1

    private final class Child: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: pid_t?
        private var cancelledAt: Date?

        func cancel() {
            lock.withLock {
                if cancelledAt == nil { cancelledAt = Date() }
                if let pid { kill(-pid, SIGTERM) }
            }
        }

        func run(wisp: URL, environment: [String: String]) -> CommandOutput? {
            let out = Pipe()
            let err = Pipe()
            let spawned: pid_t
            do {
                spawned = try ProcessCore.spawn(
                    wisp.path, arguments: arguments, environment: environment,
                    stdout: out.fileHandleForWriting.fileDescriptor, stderr: err.fileHandleForWriting.fileDescriptor)
            } catch {
                return nil
            }
            try? out.fileHandleForWriting.close()
            try? err.fileHandleForWriting.close()
            lock.withLock {
                pid = spawned
                if cancelledAt != nil { kill(-spawned, SIGTERM) }
            }
            let output = PipeDrain(out)
            let errors = PipeDrain(err)

            let deadline = Date().addingTimeInterval(timeout)
            var status: Int32 = 0
            while waitpid(spawned, &status, WNOHANG) == 0 {
                let cancelled = lock.withLock { cancelledAt }
                if Date() > deadline {
                    ProcessCore.terminateGroup(spawned)
                    return CommandOutput(status: -1, stdout: output.wait(), stderr: errors.wait(), timedOut: true)
                }
                if let cancelled, Date().timeIntervalSince(cancelled) > killGrace {
                    ProcessCore.terminateGroup(spawned)
                    return nil
                }
                Thread.sleep(forTimeInterval: 0.02)
            }
            if lock.withLock({ cancelledAt }) != nil { return nil }
            return CommandOutput(
                status: ProcessCore.exitCode(of: status), stdout: output.wait(), stderr: errors.wait(), timedOut: false)
        }
    }
}

public final class BrainColherScheduler: @unchecked Sendable {
    public static let firstDelay: TimeInterval = 120
    public static let interval: TimeInterval = 600

    private let first: TimeInterval
    private let interval: TimeInterval
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let tick: @Sendable () async -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(
        first: TimeInterval = BrainColherScheduler.firstDelay,
        interval: TimeInterval = BrainColherScheduler.interval,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
        tick: @escaping @Sendable () async -> Void
    ) {
        self.first = first
        self.interval = interval
        self.sleep = sleep
        self.tick = tick
    }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        let (first, interval, sleep, tick) = (first, interval, sleep, tick)
        task = Task.detached(priority: .utility) {
            await sleep(first)
            while !Task.isCancelled {
                await tick()
                await sleep(interval)
            }
        }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        task?.cancel()
        task = nil
    }
}
