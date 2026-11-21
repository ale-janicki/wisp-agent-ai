import CryptoKit
import Foundation

public enum BrokerError: Error, Equatable {
    case pathTooLong
    case socket(String)
}

/// The host's side of the email send gate, for every engine. A Unix socket in a private folder: the email MCP server
/// connects, sends one `request` line with the whole mail and gets `allow` only when the host approved exactly that mail.
/// Under Codex (`live`) the host shows a card and the user's Permitir answers it; under Claude the host mints a single-use
/// ticket (`authorize`) when the user allows the `can_use_tool` prompt for `email_send`, bound to a hash of the mail
/// and valid for `ticketValidity`, and the request consumes it. The only verb the client has is `request`: nothing on
/// the socket can answer a card or mint a ticket. Only a peer with the host's uid is served, and at most one card is
/// open at a time. The threads work on a separate core, so dropping the last reference to this object stops the broker
/// and removes the folder.
public final class ApprovalBroker: @unchecked Sendable {
    public static let socketEnvironment = "WISP_APPROVAL_SOCKET"
    public static let tools = BrokerCore.tools
    public static let validity: TimeInterval = BrokerCore.defaultValidity
    public static let malformed = BrokerCore.malformed
    public static let expired = BrokerCore.expired
    public static let denied = BrokerCore.denied
    public static let noTicket = BrokerCore.noTicket
    public static let busy = BrokerCore.busy
    public static let ticketValidity = BrokerCore.defaultTicketValidity

    private let core: BrokerCore

    public var path: String { core.path }

    public init(
        validity: TimeInterval = ApprovalBroker.validity,
        directory: URL = FileManager.default.temporaryDirectory,
        live: Bool = true,
        hostUID: uid_t = getuid(),
        ticketValidity: TimeInterval = ApprovalBroker.ticketValidity,
        onRequest: @escaping @Sendable (PermissionRequest) -> Void = { _ in },
        onCancel: @escaping @Sendable (String) -> Void = { _ in }
    ) throws {
        core = try BrokerCore(
            validity: validity, directory: directory, live: live, hostUID: hostUID, ticketValidity: ticketValidity,
            onRequest: onRequest, onCancel: onCancel)
    }

    deinit { core.stop() }

    @discardableResult
    public func answer(id: String, allow: Bool) -> Bool { core.answer(id: id, allow: allow) }

    public func stop() { core.stop() }

    /// Mints the single-use ticket for the mail the user just allowed. Only the host calls this; the socket has no verb for it.
    @discardableResult
    public func authorize(inputJSON: String) -> Bool { core.authorize(inputJSON: inputJSON) }

    /// Hash of the exact mail (to, cc, subject, body); the Python hosts compute the same bytes (`cli/tests/fixtures/contract/approval-broker.json`).
    public static func fingerprint(_ input: [String: Any]) -> String? { BrokerCore.fingerprint(input) }

    static func permissionRequest(_ line: Data) -> PermissionRequest? { BrokerCore.permissionRequest(line) }
}

final class BrokerCore: @unchecked Sendable {
    static let tools = ["email_send": "mcp__wisp-email__email_send", "mac_send": "mcp__wisp-mac__mac_send"]
    static let defaultValidity: TimeInterval = 610
    static let defaultTicketValidity: TimeInterval = 120
    static let maxLine = 1 << 20
    static let readTimeout: TimeInterval = 10
    static let maxPath = 103

    static let malformed = "O pedido de aprovação não foi entendido, então nada foi enviado."
    static let expired = "Ninguém respondeu ao pedido de aprovação a tempo, então nada foi enviado."
    static let denied = "O usuário negou o envio no Wisp. Não tente de novo do mesmo jeito; siga sem ele ou pergunte o que fazer."
    static let noTicket = "Não há aprovação do usuário para este e-mail exato (ou ela já foi usada ou expirou), então nada foi enviado. Peça o envio de novo e espere a aprovação."
    static let busy = "Já existe um pedido de aprovação aguardando o usuário nesta conversa, então nada foi enviado."

    let path: String
    private let folder: URL
    private let validity: TimeInterval
    private let live: Bool
    private let hostUID: uid_t
    private let ticketValidity: TimeInterval
    private var tickets: [(hash: String, instant: ContinuousClock.Instant, wall: Date)] = []
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
        live: Bool,
        hostUID: uid_t,
        ticketValidity: TimeInterval,
        onRequest: @escaping @Sendable (PermissionRequest) -> Void,
        onCancel: @escaping @Sendable (String) -> Void
    ) throws {
        self.validity = validity
        self.live = live
        self.hostUID = hostUID
        self.ticketValidity = ticketValidity
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

    func authorize(inputJSON: String) -> Bool {
        guard let input = (try? JSONSerialization.jsonObject(with: Data(inputJSON.utf8))) as? [String: Any],
              let hash = Self.fingerprint(input) else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        tickets.append((hash, ContinuousClock.now.advanced(by: .seconds(ticketValidity)), Date().addingTimeInterval(ticketValidity)))
        return true
    }

    private func consumeTicket(_ hash: String?) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = ContinuousClock.now, wall = Date()
        tickets.removeAll { $0.instant <= now || $0.wall <= wall }
        guard let hash, let index = tickets.firstIndex(where: { $0.hash == hash }) else { return false }
        tickets.remove(at: index)
        return true
    }

    static func fingerprint(_ input: [String: Any]) -> String? {
        func text(_ value: Any?) -> Data? {
            guard let string = value as? String else { return nil }
            let bytes = Data(string.utf8)
            return Data("\(bytes.count):".utf8) + bytes
        }
        func list(_ value: Any?) -> Data? {
            let items: [Any]
            if value == nil || value is NSNull {
                items = []
            } else if let array = value as? [Any] {
                items = array
            } else {
                return nil
            }
            let parts = items.map(text)
            guard !parts.contains(where: { $0 == nil }) else { return nil }
            return Data("\(parts.count)[".utf8) + parts.reduce(into: Data()) { $0.append($1!) } + Data("]".utf8)
        }
        guard let to = list(input["to"]), let cc = list(input["cc"]), let subject = text(input["subject"]),
              let body = text(input["body"]) else { return nil }
        let joined = [to, cc, subject, body].reduce(into: Data()) { total, part in
            if !total.isEmpty { total.append(0x0A) }
            total.append(part)
        }
        return SHA256.hash(data: joined).map { String(format: "%02x", $0) }.joined()
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
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, SOMAXCONN) == 0 else {
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
            var peerUID: uid_t = 0, peerGID: gid_t = 0
            guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == hostUID else {
                close(client)
                continue
            }
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
        let input = (try? JSONSerialization.jsonObject(with: Data(request.inputJSON.utf8))) as? [String: Any]
        if consumeTicket(input.flatMap(Self.fingerprint)) { return send(client, ["decision": "allow"]) }
        guard live else { return reply(client, deny: Self.noTicket) }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return reply(client, deny: Self.malformed) }
        let item = Pending(wake: fds[0], notify: fds[1])
        lock.lock()
        if stopped {
            lock.unlock()
            close(fds[0]); close(fds[1])
            return
        }
        guard pending.isEmpty else {
            lock.unlock()
            close(fds[0]); close(fds[1])
            return reply(client, deny: Self.busy)
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
