import Foundation
import Network
import Security
import WispCore

enum WebhookSendError: Error, LocalizedError {
    case resolvesPrivately(String)
    case rejected(Int)
    case redirected
    case badRequest
    case badReply
    case timedOut
    case unconfirmed

    var errorDescription: String? {
        switch self {
        case .resolvesPrivately(let host): "\(host) aponta para um endereço local ou privado."
        case .rejected(let code): "o servidor respondeu \(code)."
        case .redirected: "o servidor tentou redirecionar o envio."
        case .badRequest: "não consegui montar o pedido."
        case .badReply: "o servidor não respondeu como HTTP."
        case .timedOut: "o servidor não respondeu a tempo."
        case .unconfirmed: "o servidor não confirmou depois de receber o envio; ele pode ter chegado e não tentei de novo."
        }
    }
}

enum MeetingWebhookSender {
    private static let timeout: TimeInterval = 20

    static func send(_ pending: PendingWebhook) async throws {
        let host = pending.host
        let addresses = await Task.detached { resolved(host) }.value
        guard !addresses.isEmpty, addresses.allSatisfy({ MeetingWebhook.isPublic(host: $0) }) else {
            throw WebhookSendError.resolvesPrivately(host)
        }
        let secret = pending.signed ? WebhookKeychain.load(.secret) : nil
        let timestamp = Int(Date().timeIntervalSince1970)
        guard let request = MeetingWebhook.request(for: pending, secret: secret, timestamp: timestamp) else { throw WebhookSendError.badRequest }
        let port = UInt16(pending.url.port ?? 443)
        try await WebhookFailover.run(addresses: addresses) { address in
            let post = PinnedPost(host: host, address: address, port: port, request: request, timeout: timeout)
            do {
                let code = try await post.run()
                if (300..<400).contains(code) { return .failedAfterSend(WebhookSendError.redirected) }
                guard (200..<300).contains(code) else { return .failedAfterSend(WebhookSendError.rejected(code)) }
                return .delivered
            } catch let error as WebhookSendError {
                switch error {
                case .badReply: return .failedAfterSend(error)
                default: return post.requestHandedOver ? .failedAfterSend(WebhookSendError.unconfirmed) : .failedBeforeSend(error)
                }
            } catch {
                return post.requestHandedOver ? .failedAfterSend(WebhookSendError.unconfirmed) : .failedBeforeSend(error)
            }
        }
    }

    private static func resolved(_ host: String) -> [String] {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let first = list else { return [] }
        defer { freeaddrinfo(list) }
        var found: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor {
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if let address = entry.pointee.ai_addr,
               getnameinfo(address, entry.pointee.ai_addrlen, &name, socklen_t(name.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: name)
                if !found.contains(text) { found.append(text) }
            }
            cursor = entry.pointee.ai_next
        }
        return found
    }
}

private final class PinnedPost: @unchecked Sendable {
    private static let replyLimit = 16 * 1024

    private let host: String
    private let address: String
    private let port: UInt16
    private let request: Data
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "ai.wisp.webhook")
    private let lock = NSLock()
    private var finished = false
    private var handedOver = false
    private var reply = Data()
    private var connection: NWConnection?
    private var continuation: CheckedContinuation<Int, any Error>?

    init(host: String, address: String, port: UInt16, request: Data, timeout: TimeInterval) {
        self.host = host
        self.address = address
        self.port = port
        self.request = request
        self.timeout = timeout
    }

    var requestHandedOver: Bool { lock.withLock { handedOver } }

    func run() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            start()
        }
    }

    private func start() {
        let endpointHost = NWEndpoint.Host(address)
        switch endpointHost {
        case .ipv4, .ipv6: connect(endpointHost)
        default: finish(.failure(WebhookSendError.resolvesPrivately(host)))
        }
    }

    private func connect(_ endpointHost: NWEndpoint.Host) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return finish(.failure(WebhookSendError.badRequest)) }
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let name = host
        sec_protocol_options_set_tls_server_name(options, name)
        sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, name as CFString))
            complete(SecTrustEvaluateWithError(secTrust, nil))
        }, queue)
        let parameters = NWParameters(tls: tls)
        parameters.preferNoProxies = true
        let link = NWConnection(host: endpointHost, port: nwPort, using: parameters)
        lock.withLock { connection = link }
        link.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.send()
            case .failed(let error), .waiting(let error): self?.finish(.failure(error))
            case .cancelled: self?.finish(.failure(CancellationError()))
            default: break
            }
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(WebhookSendError.timedOut)) }
        link.start(queue: queue)
    }

    private func send() {
        guard let link = lock.withLock({ connection }) else { return }
        link.send(content: request, completion: .contentProcessed { [weak self] error in
            if let error { self?.finish(.failure(error)); return }
            self?.lock.withLock { self?.handedOver = true }
            self?.receive()
        })
    }

    private func receive() {
        guard let link = lock.withLock({ connection }) else { return }
        link.receive(minimumIncompleteLength: 1, maximumLength: Self.replyLimit) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.reply.append(data) }
            if let code = MeetingWebhook.statusCode(of: self.reply) { return self.finish(.success(code)) }
            if error != nil || complete || self.reply.count >= Self.replyLimit { return self.finish(.failure(WebhookSendError.badReply)) }
            self.receive()
        }
    }

    private func finish(_ result: Result<Int, any Error>) {
        let taken = lock.withLock { () -> (CheckedContinuation<Int, any Error>?, NWConnection?) in
            guard !finished else { return (nil, nil) }
            finished = true
            defer { continuation = nil }
            return (continuation, connection)
        }
        taken.1?.cancel()
        taken.0?.resume(with: result)
    }
}
