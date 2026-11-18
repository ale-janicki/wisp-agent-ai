import Foundation

/// posix_spawn in its own process group, pipe draining and group kill: what `BlockCommand` and `CommandRunner` share.
enum ProcessCore {
    /// `executable` is argv[0]; stdin is `/dev/null` unless a descriptor is given.
    static func spawn(
        _ executable: String, arguments: [String], environment: [String: String],
        stdin: Int32? = nil, stdout: Int32, stderr: Int32
    ) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let stdin {
            posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EINVAL) }
        return pid
    }

    static func terminateGroup(_ pid: pid_t) {
        kill(-pid, SIGTERM)
        var status: Int32 = 0
        for _ in 0..<10 {
            if waitpid(pid, &status, WNOHANG) != 0 { kill(-pid, SIGKILL); return }
            Thread.sleep(forTimeInterval: 0.02)
        }
        kill(-pid, SIGKILL)
        waitpid(pid, &status, 0)
    }

    static func exitCode(of status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : signal
    }

    /// Writes `data` to the child's stdin off the calling thread and closes it, so a large input cannot block the wait loop.
    static func feed(_ data: Data, to pipe: Pipe) {
        let handle = pipe.fileHandleForWriting
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .userInitiated).async {
            try? handle.write(contentsOf: data)
            try? handle.close()
        }
    }
}

final class PipeDrain: @unchecked Sendable {
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
