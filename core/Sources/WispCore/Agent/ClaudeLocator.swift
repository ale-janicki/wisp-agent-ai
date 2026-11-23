import Foundation

public enum AgentError: Error, Equatable, LocalizedError {
    case claudeNotFound
    case notRunning
    case configuredClaudeNotExecutable(path: String)
    case codexNotFound
    case configuredCodexNotExecutable(path: String)
    case approvalsNotRouted

    public var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "Claude Code não encontrado"
        case .notRunning:
            return "a sessão com o claude não está rodando"
        case .configuredClaudeNotExecutable(let path):
            return "o claude configurado no perfil (\(path)) não existe ou não é executável"
        case .codexNotFound:
            return "Codex não encontrado"
        case .configuredCodexNotExecutable(let path):
            return "o codex configurado (\(path)) não existe ou não é executável"
        case .approvalsNotRouted:
            return "este motor não leva pedidos de aprovação ao Wisp"
        }
    }
}

public enum ClaudeLocator {
    public static func resolve(
        configured: String?,
        shell: String = "/bin/zsh",
        home: String = NSHomeDirectory()
    ) throws -> URL {
        let fm = FileManager.default
        if let configured, !configured.isEmpty {
            let path = expandTilde(configured)
            guard fm.isExecutableFile(atPath: path) else {
                throw AgentError.configuredClaudeNotExecutable(path: path)
            }
            return URL(fileURLWithPath: path)
        }
        if let found = commandPath("claude", shell: shell), fm.isExecutableFile(atPath: found) {
            return URL(fileURLWithPath: found)
        }
        for path in [home + "/.local/bin/claude", "/opt/homebrew/bin/claude"]
        where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw AgentError.claudeNotFound
    }

    public static func commandPath(_ name: String, shell: String = "/bin/zsh") -> String? {
        guard let found = runShell(shell, script: "command -v \(name)", timeout: 5), found.hasPrefix("/") else { return nil }
        return found
    }

    public static var cachedLoginShellPATH: String? { LoginPATHCache.shared.found(fetch: { loginShellPATH() }) }

    public static var effectivePATH: String {
        cachedLoginShellPATH ?? LoginPATHCache.fallback(base: ProcessInfo.processInfo.environment["PATH"], home: NSHomeDirectory())
    }

    public static func loginShellPATH(shell: String = "/bin/zsh") -> String? {
        guard let path = runShell(shell, script: "printf %s \"$PATH\"", timeout: 5), !path.isEmpty else {
            return nil
        }
        return path
    }

    private static func runShell(_ shell: String, script: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", script]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                return nil
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let last = text.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let trimmed = last.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}


public final class LoginPATHCache: @unchecked Sendable {
    public static let shared = LoginPATHCache()
    public static let retryInterval: TimeInterval = 30
    public static let maxAttempts = 3

    private let lock = NSLock()
    private var path: String?
    private var lastAttempt: Date?
    private var attempts = 0
    private var retrying = false

    public init() {}

    public func found(now: Date = Date(), fetch: @escaping @Sendable () -> String?,
                      retry: (@escaping @Sendable () -> Void) -> Void = { work in DispatchQueue.global(qos: .utility).async(execute: work) }) -> String? {
        lock.lock()
        if let path {
            lock.unlock()
            return path
        }
        let first = attempts == 0
        let due = attempts < Self.maxAttempts && !retrying
            && (lastAttempt.map { now.timeIntervalSince($0) >= Self.retryInterval || now < $0 } ?? true)
        if due {
            attempts += 1
            lastAttempt = now
            if !first { retrying = true }
        }
        lock.unlock()
        guard due else { return nil }
        if first { return store(fetch()) }
        retry { [weak self] in
            _ = self?.store(fetch())
            self?.lock.withLock { self?.retrying = false }
        }
        return nil
    }

    private func store(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        lock.withLock { path = value }
        return value
    }

    public static func fallback(base: String?, home: String) -> String {
        let common = ["\(home)/.local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var parts: [String] = []
        for entry in (base?.split(separator: ":").map(String.init) ?? []) + common where !entry.isEmpty && !parts.contains(entry) {
            parts.append(entry)
        }
        return parts.joined(separator: ":")
    }
}
