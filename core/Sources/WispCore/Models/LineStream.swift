import Foundation

public final class LineStream: @unchecked Sendable {
    public struct Finished: Equatable, Sendable {
        public var status: Int32
        public var stderrTail: String
    }

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false

    public init() {}

    public var wasCancelled: Bool { lock.withLock { cancelled } }

    public func cancel() {
        let target: pid_t = lock.withLock {
            cancelled = true
            return pid
        }
        if target > 0 { ProcessCore.terminateGroup(target) }
    }

    public func run(
        executable: URL, arguments: [String], environment: [String: String]? = nil, onLine: @escaping @Sendable (String) -> Void
    ) async -> Result<Finished, BlockCommandError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.runBlocking(
                    executable: executable, arguments: arguments, environment: environment, onLine: onLine))
            }
        }
    }

    private func runBlocking(
        executable: URL, arguments: [String], environment: [String: String]?, onLine: @Sendable (String) -> Void
    ) -> Result<Finished, BlockCommandError> {
        let out = Pipe()
        let err = Pipe()
        let started: pid_t
        do {
            started = try ProcessCore.spawn(
                executable.path, arguments: arguments, environment: environment ?? ProcessInfo.processInfo.environment,
                stdout: out.fileHandleForWriting.fileDescriptor, stderr: err.fileHandleForWriting.fileDescriptor)
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
        try? out.fileHandleForWriting.close()
        try? err.fileHandleForWriting.close()
        let kill = lock.withLock { () -> Bool in
            pid = started
            return cancelled
        }
        if kill { ProcessCore.terminateGroup(started) }
        let errors = PipeDrain(err)
        var buffer = LineBuffer()
        let handle = out.fileHandleForReading
        while true {
            let data = handle.availableData
            if data.isEmpty { break }
            for line in buffer.append(data) { onLine(line) }
        }
        if let rest = buffer.flush() { onLine(rest) }
        var status: Int32 = 0
        waitpid(started, &status, 0)
        lock.withLock { pid = 0 }
        let tail = String(decoding: errors.wait().suffix(2048), as: UTF8.self)
        return .success(Finished(status: ProcessCore.exitCode(of: status), stderrTail: tail))
    }
}
