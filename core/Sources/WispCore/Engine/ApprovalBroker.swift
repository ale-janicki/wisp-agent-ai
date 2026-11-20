import Foundation

public enum BrokerError: Error, Equatable {
    case pathTooLong
    case socket(String)
}

/// The host's side of the email send gate under an engine with no permission prompt of its own (Codex).
/// A Unix socket in a private folder: the email MCP server connects, sends one `request` line with the whole mail
/// and gets `allow` only after the user clicks Permitir on the card the host shows for it. The only verb the client
/// has is `request`; there is no way to answer one from the socket. The threads work on a separate core, so dropping
/// the last reference to this object stops the broker and removes the folder.
public final class ApprovalBroker: @unchecked Sendable {
    public static let socketEnvironment = "WISP_APPROVAL_SOCKET"
    public static let tools = BrokerCore.tools
    public static let validity: TimeInterval = BrokerCore.defaultValidity
    public static let malformed = BrokerCore.malformed
    public static let expired = BrokerCore.expired
    public static let denied = BrokerCore.denied

    private let core: BrokerCore

    public var path: String { core.path }

    public init(
        validity: TimeInterval = ApprovalBroker.validity,
        directory: URL = FileManager.default.temporaryDirectory,
        onRequest: @escaping @Sendable (PermissionRequest) -> Void,
        onCancel: @escaping @Sendable (String) -> Void
    ) throws {
        core = try BrokerCore(validity: validity, directory: directory, onRequest: onRequest, onCancel: onCancel)
    }

    deinit { core.stop() }

    @discardableResult
    public func answer(id: String, allow: Bool) -> Bool { core.answer(id: id, allow: allow) }

    public func stop() { core.stop() }

    static func permissionRequest(_ line: Data) -> PermissionRequest? { BrokerCore.permissionRequest(line) }
}

final class BrokerCore: @unchecked Sendable {
    static let tools = ["email_send": "mcp__wisp-email__email_send"]
    static let defaultValidity: TimeInterval = 610
    static let maxLine = 1 << 20
    static let readTimeout: TimeInterval = 10
    static let maxPath = 103

    static let malformed = "O pedido de aprovação não foi entendido, então nada foi enviado."
    static let expired = "Ninguém respondeu ao pedido de aprovação a tempo, então nada foi enviado."
    static let denied = "O usuário negou o envio no Wisp. Não tente de novo do mesmo jeito; siga sem ele ou pergunte o que fazer."

    let path: String
    private let folder: URL
    private let validity: TimeInterval
    private let onRequest: @Sendable (PermissionRequest) -> Void
    private let onCancel: @Sendable (String) -> Void
    private let lock = NSLock()
    private let listener: Int32
    private var pending: [String: Pending] = [:]
    private var stopped = false

    private final class Pending: @unchecked Sendable {
        let wake: Int32
        let notify: Int32
        var allow: Bool?

        init(wake: Int32, notify: Int32) {
            self.wake = wake
            self.notify = notify
        }
    }

    init(
        validity: TimeInterval,
        directory: URL,
        onRequest: @escaping @Sendable (PermissionRequest) -> Void,
        onCancel: @escaping @Sendable (String) -> Void
    ) throws {
        self.validity = validity
        self.onRequest = onRequest
        self.onCancel = onCancel
        let temporary = directory
        Self.sweepDead(in: temporary)
        let folder = temporary.appendingPathComponent(
            "wisp-\(getpid())-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        self.folder = folder
        self.path = folder.appendingPathComponent("b").path
        do {
            self.listener = try Self.listen(path: path)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        let fd = listener
        Thread.detachNewThread { [self] in acceptLoop(fd) }
    }

    static func sweepDead(in directory: URL, fileManager: FileManager = .default) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            let parts = name.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "wisp", let pid = Int32(parts[1]), parts[2].count == 8,
                  pid != getpid(), kill(pid, 0) != 0, errno == ESRCH else { continue }
            let url = directory.appendingPathComponent(name)
            let inside = (try? fileManager.contentsOfDirectory(atPath: url.path)) ?? []
            guard inside.allSatisfy({ $0 == "b" }) else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    @discardableResult
    func answer(id: String, allow: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let item = pending[id], item.allow == nil else { return false }
        item.allow = allow
        var byte: UInt8 = 1
        _ = write(item.notify, &byte, 1)
        return true
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        for item in pending.values {
            var byte: UInt8 = 1
            _ = write(item.notify, &byte, 1)
        }
        lock.unlock()
        try? FileManager.default.removeItem(at: folder)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    // MARK: Socket

    private static func listen(path: String) throws -> Int32 {
        guard path.utf8.count <= maxPath else { throw BrokerError.pathTooLong }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BrokerError.socket(String(cString: strerror(errno))) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw BrokerError.socket(reason)
        }
        return fd
    }

    private func acceptLoop(_ fd: Int32) {
        defer { close(fd) }
        while !isStopped {
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&ready, 1, 500) > 0 else { continue }
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [self] in
                serve(client)
                close(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        guard let line = Self.readLine(client) else { return reply(client, deny: Self.malformed) }
        guard let request = Self.permissionRequest(line.text) else { return reply(client, deny: Self.malformed) }
        guard line.rest.isEmpty else { return }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return reply(client, deny: Self.malformed) }
        let item = Pending(wake: fds[0], notify: fds[1])
        lock.lock()
        if stopped {
            lock.unlock()
            close(fds[0]); close(fds[1])
            return
        }
        pending[request.id] = item
        lock.unlock()
        onRequest(request)
        let outcome = wait(client, item)
        lock.lock()
        pending[request.id] = nil
        close(fds[0]); close(fds[1])
        lock.unlock()
        switch outcome {
        case .allow: send(client, ["decision": "allow"])
        case .deny: reply(client, deny: Self.denied)
        case .expired:
            onCancel(request.id)
            reply(client, deny: Self.expired)
        case .gone:
            onCancel(request.id)
        }
    }

    private enum Outcome { case allow, deny, expired, gone }

    private func wait(_ client: Int32, _ item: Pending) -> Outcome {
        let deadline = Date().addingTimeInterval(validity)
        let clock = ContinuousClock.now.advanced(by: .seconds(validity))
        while true {
            let left = min(deadline.timeIntervalSinceNow, (clock - ContinuousClock.now).seconds)
            if left <= 0 { return .expired }
            var fds = [pollfd(fd: client, events: Int16(POLLIN), revents: 0), pollfd(fd: item.wake, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&fds, 2, Int32(min(left * 1000, 60_000)))
            if ready < 0, errno != EINTR { return .gone }
            lock.lock()
            let answered = item.allow
            lock.unlock()
            if let answered { return answered ? .allow : .deny }
            if isStopped { return .gone }
            if fds[0].revents != 0 { return .gone }
        }
    }

    private func reply(_ client: Int32, deny message: String) {
        send(client, ["decision": "deny", "message": message])
    }

    private func send(_ client: Int32, _ body: [String: String]) {
        guard var data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { buffer in
            var sent = 0
            while sent < buffer.count {
                let n = write(client, buffer.baseAddress! + sent, buffer.count - sent)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    // MARK: Protocol

    static func readLine(_ client: Int32) -> (text: Data, rest: Data)? {
        var data = Data()
        let deadline = Date().addingTimeInterval(readTimeout)
        var chunk = [UInt8](repeating: 0, count: 4096)
        while data.count <= maxLine {
            if let newline = data.firstIndex(of: 0x0A) {
                return (data.prefix(upTo: newline), data.suffix(from: newline + 1))
            }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            var fd = pollfd(fd: client, events: Int16(POLLIN), revents: 0)
            let ready = poll(&fd, 1, Int32(left * 1000))
            if ready < 0, errno == EINTR { continue }
            if ready <= 0 { return nil }
            let n = read(client, &chunk, chunk.count)
            if n <= 0 { return nil }
            data.append(contentsOf: chunk[0..<n])
        }
        return nil
    }

    /// The one verb: `request`. Anything else is not a request.
    static func permissionRequest(_ line: Data) -> PermissionRequest? {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              message["op"] as? String == "request",
              let tool = message["tool"] as? String, let name = tools[tool],
              let input = message["input"] as? [String: Any] else { return nil }
        return PermissionRequest(
            requestId: UUID().uuidString, request: ["subtype": "can_use_tool", "tool_name": name, "input": input],
            engine: "codex")
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
