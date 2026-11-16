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
            pid = try spawn(
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
                terminateGroup(pid)
                return .failure(.timedOut(seconds: Int(timeout.rounded(.up))))
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        let code = exitCode(of: status)
        let stdout = output.wait()
        guard code == 0 else {
            let message = String(data: errors.wait(), encoding: .utf8)?
                .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return .failure(.failed(status: code, message: message))
        }
        return .success(stdout)
    }

    private static func spawn(
        _ shell: String, arguments: [String], environment: [String: String], stdout: Int32, stderr: Int32
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([shell] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, shell, &actions, &attributes, argv, envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL) }
        return pid
    }

    private static func terminateGroup(_ pid: pid_t) {
        kill(-pid, SIGTERM)
        var status: Int32 = 0
        for _ in 0..<10 {
            if waitpid(pid, &status, WNOHANG) != 0 { kill(-pid, SIGKILL); return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        kill(-pid, SIGKILL)
        waitpid(pid, &status, 0)
    }

    private static func exitCode(of status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
    }
}

private final class PipeDrain: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var data = Data()

    init(_ pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let read = handle.readDataToEndOfFile()
            lock.withLock { data = read }
            group.leave()
        }
    }

    func wait() -> Data {
        _ = group.wait(timeout: .now() + 1)
        return lock.withLock { data }
    }
}
