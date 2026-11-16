import Foundation

public enum AgentError: Error, Equatable, LocalizedError {
    case claudeNotFound
    case notRunning
    case configuredClaudeNotExecutable(path: String)

    public var errorDescription: String? {
        switch self {
        case .claudeNotFound:
            return "Claude Code não encontrado"
        case .notRunning:
            return "a sessão com o claude não está rodando"
        case .configuredClaudeNotExecutable(let path):
            return "o claude configurado no perfil (\(path)) não existe ou não é executável"
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
        if let found = runShell(shell, script: "command -v claude", timeout: 5),
           found.hasPrefix("/"), fm.isExecutableFile(atPath: found) {
            return URL(fileURLWithPath: found)
        }
        for path in [home + "/.local/bin/claude", "/opt/homebrew/bin/claude"]
        where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw AgentError.claudeNotFound
    }

    public static let cachedLoginShellPATH: String? = loginShellPATH()

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
