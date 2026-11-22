import Foundation

private final class TurnCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let resumed: Bool
    private var decoder: CodexEventDecoder
    private var stdoutBuffer = LineBuffer()
    private var stderrTail = Data()
    private var stdoutEOF = false
    private var stderrEOF = false
    private var exitCode: Int32?
    private var done = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var process: Process?
    private(set) var threadId: String?

    private static let stderrLimit = 2048

    init(continuation: AsyncStream<SessionEvent>.Continuation, resumed: Bool, model: String) {
        self.continuation = continuation
        self.resumed = resumed
        self.decoder = CodexEventDecoder(model: model)
    }

    func attach(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
    }

    var processIdentifier: Int32? {
        lock.lock(); defer { lock.unlock() }
        return process?.processIdentifier
    }

    func terminate() {
        lock.lock()
        let child = exitCode == nil ? process : nil
        lock.unlock()
        if let child, child.isRunning { child.terminate() }
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
        for event in decoder.decode(line: line) { continuation.yield(.claude(event)) }
        threadId = decoder.threadId
    }

    private func finishIfReadyLocked() -> CheckedContinuation<Void, Never>? {
        guard !done, stdoutEOF, stderrEOF, let code = exitCode else { return nil }
        done = true
        let tail = String(decoding: stderrTail, as: UTF8.self)
        for event in decoder.closing(exitCode: code, stderrTail: tail, resumed: resumed) {
            continuation.yield(.claude(event))
        }
        defer { waiter = nil }
        return waiter
    }
}

public actor CodexSession: EngineSession {
    public nonisolated let events: AsyncStream<SessionEvent>
    public nonisolated var kind: EngineKind { .codex }
    public nonisolated var routesApprovals: Bool { false }
    public nonisolated var processIdentifier: Int32? { current.value?.processIdentifier }

    private let executable: URL
    private let cwd: URL
    private let permission: PermissionChoice?
    private let addDirs: [String]
    private let instructions: String
    private let model: String
    private let environmentOverrides: [String: String]
    private let approvalDirectory: URL
    private let wispBinary: String?
    private let preflight: (@Sendable (String) -> CodexPreflight)?
    private let continuation: AsyncStream<SessionEvent>.Continuation
    private let current = CurrentTurn()
    private var broker: ApprovalBroker?
    public private(set) var approvalChannelProblem: String?
    public var approvalSocketPath: String? { broker?.path }
    private var threadId: String?
    private var queue: [String] = []
    private var running = false
    private var started = false
    private var stopped = false

    public init(
        executable: URL, cwd: URL, resume: String?, permission: PermissionChoice?, addDirs: [String] = [],
        instructions: String = "", model: String = "", environmentOverrides: [String: String] = [:],
        approvalDirectory: URL = FileManager.default.temporaryDirectory, wispBinary: String? = nil,
        preflight: (@Sendable (String) -> CodexPreflight)? = nil
    ) {
        self.wispBinary = wispBinary
        self.preflight = preflight
        self.approvalDirectory = approvalDirectory
        self.executable = executable
        self.cwd = cwd
        self.threadId = resume
        self.permission = permission
        self.addDirs = addDirs
        self.instructions = instructions
        self.model = model
        self.environmentOverrides = environmentOverrides
        let (stream, continuation) = AsyncStream<SessionEvent>.makeStream()
        self.events = stream
        self.continuation = continuation
    }

    deinit {
        current.value?.terminate()
    }

    public func start() throws {
        guard !started else { return }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            continuation.yield(.exited(code: -1, stderrTail: "\(executable.path) não é executável"))
            continuation.finish()
            throw AgentError.configuredCodexNotExecutable(path: executable.path)
        }
        started = true
        let events = continuation
        do {
            broker = try ApprovalBroker(
                directory: approvalDirectory,
                onRequest: { events.yield(.claude(.permissionRequest($0))) },
                onCancel: { events.yield(.claude(.permissionCancelled(id: $0))) })
        } catch {
            approvalChannelProblem = "\(error)"
        }
    }

    public func send(_ text: String) throws {
        guard started, !stopped else { throw AgentError.notRunning }
        queue.append(text)
        pump()
    }

    public func respond(to request: PermissionRequest, _ decision: PermissionDecision) throws {
        guard let broker, broker.answer(id: request.id, allow: decision.allows) else { throw AgentError.approvalsNotRouted }
    }

    public func stop() async {
        stopped = true
        broker?.stop()
        broker = nil
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
        guard let wispBinary, !wispBinary.isEmpty else {
            continuation.yield(.exited(code: -1, stderrTail: Self.noWispBinary))
            return
        }
        var owned: Set<String> = []
        if let preflight {
            let workspace = cwd.path
            let verdict = await Task.detached(operation: { preflight(workspace) }).value
            if let problem = verdict.problem {
                continuation.yield(.exited(code: -1, stderrTail: problem))
                return
            }
            owned = verdict.ownedByUser
        }
        let collector = TurnCollector(continuation: continuation, resumed: threadId != nil, model: model)
        let process = Process()
        process.executableURL = executable
        process.arguments = CodexCommand.arguments(
            workspace: cwd.path, permission: permission, addDirs: addDirs, instructions: instructions,
            wispBinary: wispBinary, resume: threadId, ownedByUser: owned)
        process.currentDirectoryURL = cwd
        process.environment = childEnvironment()
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            collector.receiveStdout(data)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            collector.receiveStderr(data)
        }
        process.terminationHandler = { finished in
            collector.receiveTermination(finished.terminationStatus)
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { collector.forceExit() }
        }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            process.terminationHandler = nil
            continuation.yield(.exited(code: -1, stderrTail: String(describing: error)))
            return
        }
        collector.attach(process)
        current.value = collector
        let handle = stdin.fileHandleForWriting
        let payload = Data(prompt.utf8)
        DispatchQueue.global().async {
            try? handle.write(contentsOf: payload)
            try? handle.close()
        }
        await collector.finished()
        current.value = nil
        if let id = collector.threadId { threadId = id }
    }

    public static let noWispBinary = "não achei o CLI do Wisp; o Codex não roda sem a trava de aprovação do e-mail"

    private func childEnvironment() -> [String: String] {
        var env = CodexCommand.environment(executable: executable, overrides: environmentOverrides, wispBinary: wispBinary)
        env[ApprovalBroker.socketEnvironment] = broker?.path
        return env
    }
}

private final class CurrentTurn: @unchecked Sendable {
    private let lock = NSLock()
    private var collector: TurnCollector?

    var value: TurnCollector? {
        get { lock.lock(); defer { lock.unlock() }; return collector }
        set { lock.lock(); collector = newValue; lock.unlock() }
    }
}
