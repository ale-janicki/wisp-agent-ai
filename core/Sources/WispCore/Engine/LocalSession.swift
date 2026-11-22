import Foundation

private final class LocalTurn: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private var stdoutBuffer = LineBuffer()
    private var stderrTail = Data()
    private var stdoutEOF = false
    private var stderrEOF = false
    private var exitCode: Int32?
    private var done = false
    private var sawResult = false
    private var reportedError: String?
    private var waiter: CheckedContinuation<Void, Never>?
    private var process: Process?
    private var stdin: FileHandle?

    private static let stderrLimit = 2048

    init(continuation: AsyncStream<SessionEvent>.Continuation) {
        self.continuation = continuation
    }

    func attach(_ process: Process, stdin: FileHandle) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        self.stdin = stdin
    }

    var processIdentifier: Int32? {
        lock.lock(); defer { lock.unlock() }
        return process?.processIdentifier
    }

    func write(_ data: Data) throws {
        lock.lock()
        let handle = done || exitCode != nil ? nil : stdin
        lock.unlock()
        guard let handle else { throw AgentError.notRunning }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw AgentError.notRunning
        }
    }

    func terminate() {
        lock.lock()
        let child = exitCode == nil ? process : nil
        lock.unlock()
        closeStdin()
        if let child, child.isRunning { child.terminate() }
    }

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
        let waiter = finishIfReadyLocked()
        lock.unlock()
        waiter?.resume()
    }

    func receiveStderr(_ data: Data) {
        lock.lock()
        if data.isEmpty {
            stderrEOF = true
        } else {
            stderrTail.append(data)
            if stderrTail.count > Self.stderrLimit { stderrTail = Data(stderrTail.suffix(Self.stderrLimit)) }
        }
        let waiter = finishIfReadyLocked()
        lock.unlock()
        waiter?.resume()
    }

    func receiveTermination(_ code: Int32) {
        lock.lock()
        exitCode = code
        let waiter = finishIfReadyLocked()
        lock.unlock()
        waiter?.resume()
    }

    func forceExit() {
        lock.lock()
        stdoutEOF = true
        stderrEOF = true
        let waiter = finishIfReadyLocked()
        lock.unlock()
        waiter?.resume()
    }

    func finished() async {
        await withCheckedContinuation { (next: CheckedContinuation<Void, Never>) in
            lock.lock()
            if done {
                lock.unlock()
                next.resume()
            } else {
                waiter = next
                lock.unlock()
            }
        }
    }

    private func yieldLocked(_ line: String) {
        if let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
           object["type"] as? String == "error", let message = object["message"] as? String {
            reportedError = message
        }
        for event in ClaudeStreamDecoder.decode(line: line) {
            if case .result = event { sawResult = true }
            continuation.yield(.claude(event))
        }
    }

    private func finishIfReadyLocked() -> CheckedContinuation<Void, Never>? {
        guard !done, stdoutEOF, stderrEOF, let code = exitCode else { return nil }
        done = true
        if !sawResult {
            let tail = String(decoding: stderrTail, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = reportedError ?? (tail.isEmpty ? "a IA local terminou sem concluir o turno (código \(code))" : tail)
            continuation.yield(.claude(.result(sessionId: "", text: detail, isError: true, denials: [])))
        }
        let stdinHandle = stdin
        stdin = nil
        try? stdinHandle?.close()
        defer { waiter = nil }
        return waiter
    }
}

private final class CurrentLocalTurn: @unchecked Sendable {
    private let lock = NSLock()
    private var turn: LocalTurn?

    var value: LocalTurn? {
        get { lock.lock(); defer { lock.unlock() }; return turn }
        set { lock.lock(); turn = newValue; lock.unlock() }
    }
}

public actor LocalSession: EngineSession {
    public nonisolated let events: AsyncStream<SessionEvent>
    public nonisolated var kind: EngineKind { .local }
    public nonisolated var routesApprovals: Bool { true }
    public nonisolated var processIdentifier: Int32? { current.value?.processIdentifier }

    private let executable: URL
    private let cwd: URL
    private let conversation: String
    private let mode: String
    private let environment: [String: String]?
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let current = CurrentLocalTurn()
    private var queue: [String] = []
    private var running = false
    private var started = false
    private var stopped = false

    public init(
        executable: URL, cwd: URL, conversation: String, mode: String = "default", environment: [String: String]? = nil
    ) {
        self.executable = executable
        self.cwd = cwd
        self.conversation = conversation
        self.mode = mode
        self.environment = environment
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
    }

    deinit {
        current.value?.terminate()
    }

    public static func arguments(text: String, conversation: String, mode: String) -> [String] {
        var args = ["local", "chat", "--message=\(text)", "--approvals", "stdio", "--no-record", "--recorded", "--surface", "app", "--mode", mode]
        if !conversation.isEmpty { args += ["--conversation", conversation] }
        return args
    }

    public func start() throws {
        guard !started else { return }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            continuation.yield(.exited(code: -1, stderrTail: "\(executable.path) não é executável"))
            continuation.finish()
            throw AgentError.notRunning
        }
        started = true
    }

    public func send(_ text: String) throws {
        guard started, !stopped else { throw AgentError.notRunning }
        queue.append(text)
        pump()
    }

    public func respond(to request: PermissionRequest, _ decision: PermissionDecision) throws {
        guard let turn = current.value else { throw AgentError.notRunning }
        try turn.write(ClaudeControl.response(to: request, decision))
    }

    public func stop() async {
        stopped = true
        queue = []
        current.value?.terminate()
        continuation.finish()
    }

    private func pump() {
        guard !running, !stopped, !queue.isEmpty else { return }
        running = true
        let prompt = queue.removeFirst()
        Task { [weak self] in
            await self?.runTurn(prompt)
            await self?.turnEnded()
        }
    }

    private func turnEnded() {
        running = false
        pump()
    }

    private func runTurn(_ prompt: String) async {
        signal(SIGPIPE, SIG_IGN)
        let turn = LocalTurn(continuation: continuation)
        let process = Process()
        process.executableURL = executable
        process.arguments = Self.arguments(text: prompt, conversation: conversation, mode: mode)
        process.currentDirectoryURL = cwd
        process.environment = environment ?? ProcessInfo.processInfo.environment
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            turn.receiveStdout(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            turn.receiveStderr(data)
        }
        process.terminationHandler = { finished in
            turn.receiveTermination(finished.terminationStatus)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { turn.forceExit() }
        }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            continuation.yield(.claude(.result(sessionId: "", text: "não consegui iniciar a IA local: \(error.localizedDescription)", isError: true, denials: [])))
            return
        }
        turn.attach(process, stdin: stdin.fileHandleForWriting)
        current.value = turn
        await turn.finished()
        current.value = nil
    }
}
