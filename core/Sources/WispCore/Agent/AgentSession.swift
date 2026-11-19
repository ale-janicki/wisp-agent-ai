import Foundation

public enum SessionEvent: Sendable, Equatable {
    case claude(ClaudeEvent)
    case exited(code: Int32, stderrTail: String)
}

private final class SessionState: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private var stdoutBuffer = LineBuffer()
    private var stderrTail = Data()
    private var stdoutEOF = false
    private var stderrEOF = false
    private var exitCode: Int32?
    private var emitted = false
    private var stdin: FileHandle?
    private var started = false
    private var process: Process?

    private static let stderrLimit = 2048

    init(continuation: AsyncStream<SessionEvent>.Continuation) {
        self.continuation = continuation
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return started && !emitted && exitCode == nil
    }

    var hasExited: Bool {
        lock.lock(); defer { lock.unlock() }
        return exitCode != nil
    }

    func markStarted(process: Process, stdin: FileHandle) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        self.stdin = stdin
        started = true
    }

    var processIdentifier: Int32? {
        lock.lock(); defer { lock.unlock() }
        return process?.processIdentifier
    }

    func shutdown() {
        closeStdin()
        lock.lock()
        let child = exitCode == nil ? process : nil
        lock.unlock()
        if let child, child.isRunning { child.terminate() }
    }

    func failLaunch(_ message: String) {
        lock.lock()
        emitted = true
        lock.unlock()
        continuation.yield(.exited(code: -1, stderrTail: message))
        continuation.finish()
    }

    func stdinHandle() -> FileHandle? {
        lock.lock(); defer { lock.unlock() }
        return isRunningLocked ? stdin : nil
    }

    private var isRunningLocked: Bool { started && !emitted && exitCode == nil }

    func closeStdin() {
        lock.lock()
        let handle = stdin
        stdin = nil
        lock.unlock()
        try? handle?.close()
    }

    func receiveStdout(_ data: Data) {
        lock.lock()
        if data.isEmpty {
            stdoutEOF = true
            if let rest = stdoutBuffer.flush() { yieldLocked(rest) }
        } else {
            for line in stdoutBuffer.append(data) { yieldLocked(line) }
        }
        let event = takeExitIfReadyLocked()
        lock.unlock()
        finish(event)
    }

    func receiveStderr(_ data: Data) {
        lock.lock()
        if data.isEmpty {
            stderrEOF = true
        } else {
            stderrTail.append(data)
            if stderrTail.count > Self.stderrLimit {
                stderrTail = Data(stderrTail.suffix(Self.stderrLimit))
            }
        }
        let event = takeExitIfReadyLocked()
        lock.unlock()
        finish(event)
    }

    func receiveTermination(code: Int32) {
        lock.lock()
        exitCode = code
        let event = takeExitIfReadyLocked()
        lock.unlock()
        finish(event)
    }

    func forceExit() {
        lock.lock()
        stdoutEOF = true
        stderrEOF = true
        let event = takeExitIfReadyLocked()
        lock.unlock()
        finish(event)
    }

    private func yieldLocked(_ line: String) {
        for event in ClaudeStreamDecoder.decode(line: line) {
            continuation.yield(.claude(event))
        }
    }

    private func takeExitIfReadyLocked() -> SessionEvent? {
        guard !emitted, stdoutEOF, stderrEOF, let code = exitCode else { return nil }
        emitted = true
        let tail = String(decoding: stderrTail, as: UTF8.self)
        return .exited(code: code, stderrTail: tail)
    }

    private func finish(_ event: SessionEvent?) {
        guard let event else { return }
        continuation.yield(event)
        continuation.finish()
    }
}

public actor AgentSession {
    public nonisolated let events: AsyncStream<SessionEvent>

    private let executable: URL
    private let cwd: URL
    private let model: String?
    private let resume: String?
    private let permissionMode: String?
    private let appendSystemPrompt: String?
    private let settingsPath: String?
    private let disallowedTools: [String]
    private let environmentOverrides: [String: String]
    private let state: SessionState
    private var process: Process?

    public init(
        executable: URL,
        cwd: URL,
        model: String?,
        resume: String?,
        permissionMode: String? = nil,
        appendSystemPrompt: String? = nil,
        settingsPath: String? = nil,
        disallowedTools: [String] = [],
        environmentOverrides: [String: String] = [:]
    ) {
        self.executable = executable
        self.cwd = cwd
        self.model = model
        self.resume = resume
        self.permissionMode = permissionMode
        self.appendSystemPrompt = appendSystemPrompt
        self.settingsPath = settingsPath
        self.disallowedTools = disallowedTools
        self.environmentOverrides = environmentOverrides
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream()
        self.events = stream
        self.state = SessionState(continuation: continuation)
    }

    public func start() throws {
        guard process == nil else { return }
        signal(SIGPIPE, SIG_IGN)

        let process = Process()
        process.executableURL = executable
        process.arguments = ClaudeCommand.arguments(model: model, resume: resume, permissionMode: permissionMode, appendSystemPrompt: appendSystemPrompt, settings: settingsPath, disallowedTools: disallowedTools)
        process.currentDirectoryURL = cwd
        process.environment = childEnvironment()

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        let state = self.state
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            state.receiveStdout(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            state.receiveStderr(data)
        }
        process.terminationHandler = { finished in
            state.receiveTermination(code: finished.terminationStatus)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { state.forceExit() }
        }

        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            state.failLaunch(String(describing: error))
            throw error
        }
        self.process = process
        state.markStarted(process: process, stdin: stdin.fileHandleForWriting)
    }

    public nonisolated var processIdentifier: Int32? { state.processIdentifier }

    deinit {
        state.shutdown()
    }

    public func send(_ text: String) throws {
        let payload: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)
        try write(data)
    }

    public func respond(to request: PermissionRequest, _ decision: PermissionDecision) throws {
        try write(ClaudeControl.response(to: request, decision))
    }

    private func write(_ data: Data) throws {
        guard let handle = state.stdinHandle() else { throw AgentError.notRunning }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw AgentError.notRunning
        }
    }

    public func stop() async {
        guard let process else { return }
        state.closeStdin()
        let deadline = Date().addingTimeInterval(3)
        while !state.hasExited, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if !state.hasExited { process.terminate() }
    }

    private func childEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if let path = ClaudeLocator.cachedLoginShellPATH {
            env["PATH"] = path
        } else {
            let current = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = current + ":" + executable.deletingLastPathComponent().path
                + ":/opt/homebrew/bin:/usr/local/bin"
        }
        for (key, value) in environmentOverrides { env[key] = value }
        return env
    }
}
