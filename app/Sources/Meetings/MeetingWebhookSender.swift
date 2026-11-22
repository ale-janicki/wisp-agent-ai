import Foundation
import WispCore

enum WebhookSendError: Error, LocalizedError {
    case resolvesPrivately(String)
    case rejected(Int)
    case redirected

    var errorDescription: String? {
        switch self {
        case .resolvesPrivately(let host): "\(host) aponta para um endereço local ou privado."
        case .rejected(let code): "o servidor respondeu \(code)."
        case .redirected: "o servidor tentou redirecionar o envio."
        }
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: pending.url)
        request.httpMethod = "POST"
        request.httpBody = pending.body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Wisp", forHTTPHeaderField: "User-Agent")
        let (_, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (300..<400).contains(code) { throw WebhookSendError.redirected }
        guard (200..<300).contains(code) else { throw WebhookSendError.rejected(code) }
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
                found.append(String(cString: name))
            }
            cursor = entry.pointee.ai_next
        }
        return found
    }
}
