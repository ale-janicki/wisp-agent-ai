import Foundation

public enum BlockCommandError: Error, Equatable, LocalizedError {
    case launchFailed(String)
    case timedOut(seconds: Int)
    case failed(status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let reason): "não consegui rodar o comando: \(reason)"
        case .timedOut(let seconds): "o comando passou de \(seconds) s"
        case .failed(let status, let message):
            message.isEmpty ? "o comando saiu com código \(status)" : message
        }
    }
}

public enum BlockCommand {
    public static func run(
        _ command: String,
        timeout: TimeInterval = 5,
        path: String? = ClaudeLocator.cachedLoginShellPATH,
        shell: String = "/bin/zsh"
    ) -> Result<Data, BlockCommandError> {
        var environment = ProcessInfo.processInfo.environment
        if let path { environment["PATH"] = path }
        let out = Pipe()
        let err = Pipe()

        let pid: pid_t
        do {
            pid = try ProcessCore.spawn(
                shell, arguments: ["-c", command], environment: environment,
                stdout: out.fileHandleForWriting.fileDescriptor, stderr: err.fileHandleForWriting.fileDescriptor
            )
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        let output = PipeDrain(out)
        let errors = PipeDrain(err)

        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        while waitpid(pid, &status, WNOHANG) == 0 {
            if Date() > deadline {
                ProcessCore.terminateGroup(pid)
                return .failure(.timedOut(seconds: Int(timeout.rounded(.up))))
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let code = ProcessCore.exitCode(of: status)
        let stdout = output.wait()
        guard code == 0 else {
            let message = String(data: errors.wait(), encoding: .utf8)?
                .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return .failure(.failed(status: code, message: message))
        }
        return .success(stdout)
    }
}
