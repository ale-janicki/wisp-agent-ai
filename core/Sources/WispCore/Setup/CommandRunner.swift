import Foundation

public struct CommandOutput: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public init(status: Int32, stdout: Data, stderr: Data, timedOut: Bool) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Runs one program and keeps what it printed, whatever its exit code: `wisp ... --json` prints its report on a failure too.
public enum CommandRunner {
    /// Only a launch failure is an error; a non-zero exit or a timeout is a `CommandOutput`.
    /// `environment` nil inherits this process's. A timeout kills the whole process group (status -1).
    public static func run(
        executable: URL, arguments: [String], stdin: Data? = nil, environment: [String: String]? = nil,
        timeout: TimeInterval
    ) -> Result<CommandOutput, BlockCommandError> {
        let out = Pipe()
        let err = Pipe()
        let input = stdin.map { _ in Pipe() }

        let pid: pid_t
        do {
            pid = try ProcessCore.spawn(
                executable.path, arguments: arguments, environment: environment ?? ProcessInfo.processInfo.environment,
                stdin: input?.fileHandleForReading.fileDescriptor,
                stdout: out.fileHandleForWriting.fileDescriptor, stderr: err.fileHandleForWriting.fileDescriptor)
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        try? input?.fileHandleForReading.close()
        if let stdin, let input { ProcessCore.feed(stdin, to: input) }
        let output = PipeDrain(out)
        let errors = PipeDrain(err)

        let deadline = Date().addingTimeInterval(timeout)
        var status: Int32 = 0
        while waitpid(pid, &status, WNOHANG) == 0 {
            if Date() > deadline {
                ProcessCore.terminateGroup(pid)
                return .success(CommandOutput(status: -1, stdout: output.wait(), stderr: errors.wait(), timedOut: true))
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return .success(CommandOutput(
            status: ProcessCore.exitCode(of: status), stdout: output.wait(), stderr: errors.wait(), timedOut: false))
    }
}
