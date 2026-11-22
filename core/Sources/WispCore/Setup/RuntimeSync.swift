import Darwin
import Foundation

public struct SyncWatchdog: Sendable {
    public var idle: TimeInterval
    public var quiet: TimeInterval
    public var sample: TimeInterval

    public init(idle: TimeInterval = 180, quiet: TimeInterval = 20, sample: TimeInterval = 5) {
        self.idle = idle
        self.quiet = quiet
        self.sample = sample
    }
}

public enum RuntimeSync {
    public static let lockTimeoutSeconds = 120
    public static let lockFailure = "O instalador ficou esperando outro processo do Wisp ou do uv. Feche as outras janelas do Wisp e tente de novo."
    public static let idleFailure = "A instalação ficou parada sem progresso. Confira a internet e tente de novo."
    private static let offlineMarkers = [
        "dns", "network", "offline", "internet", "connection", "connect", "resolve", "lookup", "timed out",
        "error sending request", "failed to fetch", "failed to download", "tcp",
    ]
    private static let lockMarkers = ["could not acquire lock", "when waiting for lock", "is another uv process running"]

    public static func watchedFolders(_ root: URL, venv: URL) -> [URL] {
        ["cache", "python", "tmp"].map { root.appendingPathComponent($0, isDirectory: true) } + [venv]
    }

    private enum Attempt {
        case ok, stalled, lockBusy, failed(String)
    }

    public static func run(
        executable: URL, arguments: [String], environment: [String: String], watch: [URL],
        watchdog: SyncWatchdog = SyncWatchdog(), onStep: @escaping @Sendable (String) -> Void = { _ in }
    ) -> String? {
        let progress = Activity(onStep: onStep)
        var outcome = attempt(executable, arguments, environment, watch, watchdog, progress)
        switch outcome {
        case .stalled, .lockBusy: outcome = attempt(executable, arguments, environment, watch, watchdog, progress)
        default: break
        }
        let suffix = progress.step.map { " Último passo: \($0)." } ?? ""
        switch outcome {
        case .ok: return nil
        case .stalled: return idleFailure + suffix
        case .lockBusy: return lockFailure + suffix
        case .failed(let message): return message + suffix
        }
    }

    public enum FailureKind: Equatable, Sendable {
        case lock, stalled, offline, other
    }

    public static func classify(_ text: String) -> FailureKind {
        if text.hasPrefix(lockFailure) { return .lock }
        if text.hasPrefix(idleFailure) { return .stalled }
        let lower = text.lowercased()
        return offlineMarkers.contains { lower.contains($0) } ? .offline : .other
    }

    public static func isLockWait(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lockMarkers.contains { lower.contains($0) }
    }

    public static func step(from line: String) -> String? {
        let lower = line.lowercased()
        let words = line.split(separator: " ").map(String.init)
        guard let first = words.first?.lowercased() else { return nil }
        let name = words.dropFirst().first.map { $0.split(separator: "=").first.map(String.init) ?? $0 } ?? ""
        let label = name.isEmpty || name.allSatisfy(\.isNumber) ? "os pacotes" : name
        let python = lower.contains("cpython") || lower.contains("python-build")
        switch first {
        case "downloading": return python ? "baixando o Python" : "baixando \(label)"
        case "installing", "installed": return python ? "instalando o Python" : "instalando \(label)"
        case "building", "built": return "construindo \(label)"
        case "prepared": return "preparando os pacotes"
        case "resolved", "resolving": return "resolvendo as dependências"
        default: return nil
        }
    }

    private final class Activity: @unchecked Sendable {
        private let lock = NSLock()
        private var lastActivity = Date()
        private var lastStep: String?
        private let onStep: @Sendable (String) -> Void

        init(onStep: @escaping @Sendable (String) -> Void) { self.onStep = onStep }

        var step: String? { lock.withLock { lastStep } }
        var idleFor: TimeInterval { lock.withLock { Date().timeIntervalSince(lastActivity) } }

        func touch() { lock.withLock { lastActivity = Date() } }

        func lines(_ text: String) {
            touch()
            for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                guard let found = RuntimeSync.step(from: line.trimmingCharacters(in: .whitespaces)) else { continue }
                let changed = lock.withLock { () -> Bool in
                    defer { lastStep = found }
                    return lastStep != found
                }
                if changed { onStep(found) }
            }
        }
    }

    private static func footprint(_ roots: [URL]) -> Int {
        var total = 0
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in walker {
                total += 1 + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }

    private static func attempt(
        _ executable: URL, _ arguments: [String], _ environment: [String: String], _ watch: [URL],
        _ watchdog: SyncWatchdog, _ progress: Activity
    ) -> Attempt {
        let out = Pipe()
        let err = Pipe()
        let pid: pid_t
        do {
            pid = try ProcessCore.spawn(
                executable.path, arguments: arguments, environment: environment,
                stdout: out.fileHandleForWriting.fileDescriptor, stderr: err.fileHandleForWriting.fileDescriptor)
        } catch {
            return .failed("Não consegui rodar o instalador: \(error.localizedDescription)")
        }
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        progress.touch()
        let group = DispatchGroup()
        let captured = NSMutableData()
        let captureLock = NSLock()
        for (pipe, keep) in [(out, false), (err, true)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let handle = pipe.fileHandleForReading
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    progress.lines(String(decoding: data, as: UTF8.self))
                    if keep { captureLock.withLock { captured.append(data) } }
                }
                group.leave()
            }
        }

        var status: Int32 = 0
        var sampledAt = Date()
        var lastFootprint = -1
        var waited: pid_t = 0
        var waitError: Int32 = 0
        while true {
            waited = waitpid(pid, &status, WNOHANG)
            if waited == -1 {
                if errno == EINTR { continue }
                waitError = errno
                break
            }
            if waited != 0 { break }
            if progress.idleFor > watchdog.quiet, Date().timeIntervalSince(sampledAt) >= watchdog.sample {
                sampledAt = Date()
                let now = footprint(watch)
                if lastFootprint >= 0, now != lastFootprint { progress.touch() }
                lastFootprint = now
            }
            if progress.idleFor > watchdog.idle {
                ProcessCore.terminateGroup(pid)
                _ = group.wait(timeout: .now() + 1)
                return .stalled
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        _ = group.wait(timeout: .now() + 1)
        if waitError != 0 { return .failed("Não consegui acompanhar o instalador (erro \(waitError)).") }
        if ProcessCore.exitCode(of: status) == 0 { return .ok }
        let text = String(decoding: captureLock.withLock { Data(captured) }, as: UTF8.self)
        if isLockWait(text) { return .lockBusy }
        let last = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.last { !$0.isEmpty }
        return .failed(last ?? "A instalação falhou (código \(ProcessCore.exitCode(of: status))).")
    }
}
