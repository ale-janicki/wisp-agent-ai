import CryptoKit
import Foundation

public enum WebhookError: Error, LocalizedError, Equatable {
    case invalid
    case notHTTPS
    case credentials
    case privateHost(String)

    public var errorDescription: String? {
        switch self {
        case .invalid: "O endereço do webhook não é uma URL válida."
        case .notHTTPS: "O webhook precisa de um endereço https."
        case .credentials: "O endereço do webhook não pode ter usuário e senha."
        case .privateHost(let host): "O webhook não pode apontar para \(host): é um endereço local ou privado."
        }
    }
}

public struct ActionItem: Codable, Equatable, Sendable {
    public var text: String
    public var owner: String?
    public var due: String?

    private enum CodingKeys: String, CodingKey { case text, owner, due }
}

public struct PendingWebhook: Equatable, Sendable {
    public var url: URL
    public var body: Data
    public var preview: String
    public var signature: String?

    public init(url: URL, body: Data, preview: String = "", signature: String? = nil) {
        self.url = url
        self.body = body
        self.preview = preview
        self.signature = signature
    }

    public var host: String { url.host ?? url.absoluteString }

    public var maskedURL: String {
        let path = url.path
        let hidden = path.isEmpty || path == "/" ? "" : "/•••"
        return "\(url.scheme ?? "https")://\(url.host ?? "")\(url.port.map { ":\($0)" } ?? "")\(hidden)"
    }

    public var sizeText: String {
        body.count < 1024 ? "\(body.count) B" : String(format: "%.1f KB", Double(body.count) / 1024)
    }
}

public struct WebhookContent: Equatable, Sendable {
    public var body: Data
    public var preview: String
}

public enum MeetingWebhook {
    public static let maximumURLLength = 2048
    public static let previewLimit = 280

    public static func validate(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumURLLength, let components = URLComponents(string: trimmed),
              let host = components.host?.lowercased(), !host.isEmpty, let url = components.url else { throw WebhookError.invalid }
        guard components.scheme?.lowercased() == "https" else { throw WebhookError.notHTTPS }
        guard components.user == nil, components.password == nil else { throw WebhookError.credentials }
        guard isPublic(host: host) else { throw WebhookError.privateHost(host) }
        return url
    }

    public static func isPublic(host raw: String) -> Bool {
        let host = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if host.contains(":") { return publicIPv6(host) }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if let last = labels.last, last.allSatisfy(\.isNumber) || last.hasPrefix("0x") {
            guard let v4 = ipv4(host) else { return false }
            return publicIPv4(v4)
        }
        guard labels.count >= 2 else { return false }
        if host == "localhost" { return false }
        let blocked = ["localhost", "local", "internal", "lan", "home", "corp", "intranet", "arpa", "test", "invalid", "example"]
        return !blocked.contains(labels.last ?? "")
    }

    public static func content(
        title: String, startedAt: Date, durationSeconds: Double, note: String, metrics: MeetingMetrics?
    ) throws -> WebhookContent {
        struct Body: Encodable {
            var event: String
            var title: String
            var startedAt: Date
            var durationSeconds: Double
            var overview: String
            var keyPoints: String
            var actionItems: [ActionItem]
            var metrics: MeetingMetrics?

            enum CodingKeys: String, CodingKey {
                case event, title, overview, metrics
                case startedAt = "started_at"
                case durationSeconds = "duration_s"
                case keyPoints = "key_points"
                case actionItems = "action_items"
            }
        }
        let overview = section("## Resumo", in: note)
        let keyPoints = section("## Pontos principais", in: note)
        let actions = actionItems(in: note)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(Body(
            event: "meeting.finished", title: title, startedAt: startedAt, durationSeconds: durationSeconds, overview: overview,
            keyPoints: keyPoints, actionItems: actions, metrics: metrics
        ))
        let topics = keyPoints.split(separator: "\n").filter { $0.hasPrefix("### ") }.count
        let lead = overview.count > previewLimit ? String(overview.prefix(previewLimit)) + "…" : overview
        let counts = "\(topics) tópico(s) · \(actions.count) ação(ões)"
        return WebhookContent(body: body, preview: lead.isEmpty ? counts : "\(lead)\n\(counts)")
    }

    public static func section(_ heading: String, in note: String) -> String {
        var inside = false
        var captured = false
        var lines: [String] = []
        for line in note.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                if inside { captured = true }
                inside = !captured && trimmed == heading
                continue
            }
            if inside, !trimmed.hasPrefix(">") { lines.append(String(line)) }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func signature(body: Data, secret: String) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
        return "sha256=" + code.map { String(format: "%02x", $0) }.joined()
    }

    public static func request(for pending: PendingWebhook) -> Data? {
        guard let components = URLComponents(url: pending.url, resolvingAgainstBaseURL: false), let host = components.host else { return nil }
        var target = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { target += "?" + query }
        let port = components.port.map { $0 == 443 ? "" : ":\($0)" } ?? ""
        let authority = (host.contains(":") ? "[\(host)]" : host) + port
        var lines = [
            "POST \(target) HTTP/1.1", "Host: \(authority)", "Content-Type: application/json", "Content-Length: \(pending.body.count)",
            "User-Agent: Wisp", "Connection: close",
        ]
        if let signature = pending.signature { lines.append("X-Wisp-Signature: \(signature)") }
        guard lines.allSatisfy({ $0.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F } }), !target.contains(" ") else { return nil }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + pending.body
    }

    public static func statusCode(of response: Data) -> Int? {
        guard let line = String(decoding: response.prefix(64), as: UTF8.self).split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), parts[1].count == 3, let code = Int(parts[1]) else { return nil }
        return code
    }

    public static func actionItems(in note: String) -> [ActionItem] {
        var inside = false
        var items: [ActionItem] = []
        for line in note.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("## ") {
                inside = trimmed == "## Ações"
                continue
            }
            guard inside, let checkbox = ["- [ ] ", "- [x] ", "- [X] "].first(where: trimmed.hasPrefix) else { continue }
            let parts = trimmed.dropFirst(checkbox.count).components(separatedBy: " — ")
            let text = parts[0].trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            items.append(ActionItem(text: text, owner: value("responsável:", in: parts), due: value("prazo:", in: parts)))
        }
        return items
    }

    private static func value(_ label: String, in parts: [String]) -> String? {
        guard let part = parts.dropFirst().first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(label) }) else { return nil }
        let value = part.trimmingCharacters(in: .whitespaces).dropFirst(label.count).trimmingCharacters(in: .whitespaces)
        return value.isEmpty || value == "não definido" ? nil : value
    }

    private static func ipv4(_ host: String) -> in_addr? {
        var address = in_addr()
        return inet_aton(host, &address) == 1 ? address : nil
    }

    private static func publicIPv4(_ address: in_addr) -> Bool {
        let value = UInt32(bigEndian: address.s_addr)
        let blocks: [(UInt32, UInt32)] = [
            (0x0000_0000, 8), (0x0A00_0000, 8), (0x6440_0000, 10), (0x7F00_0000, 8), (0xA9FE_0000, 16), (0xAC10_0000, 12),
            (0xC000_0000, 24), (0xC000_0200, 24), (0xC0A8_0000, 16), (0xC612_0000, 15), (0xC633_6400, 24), (0xCB00_7100, 24),
            (0xE000_0000, 3),
        ]
        return !blocks.contains { base, bits in value >> (32 - bits) == base >> (32 - bits) }
    }

    private static func publicIPv6(_ host: String) -> Bool {
        var address = in6_addr()
        guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
        let bytes = withUnsafeBytes(of: address) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            var v4 = in_addr()
            v4.s_addr = UInt32(bytes[12]) | UInt32(bytes[13]) << 8 | UInt32(bytes[14]) << 16 | UInt32(bytes[15]) << 24
            return publicIPv4(v4)
        }
        guard bytes[0] & 0xE0 == 0x20 else { return false }
        if bytes[0] == 0x20, bytes[1] == 0x02 {
            var v4 = in_addr()
            v4.s_addr = UInt32(bytes[2]) | UInt32(bytes[3]) << 8 | UInt32(bytes[4]) << 16 | UInt32(bytes[5]) << 24
            return publicIPv4(v4)
        }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x00, bytes[3] == 0x00 { return false }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 { return false }
        return true
    }
}

public struct WebhookApproval: Equatable, Sendable {
    public private(set) var offers: [String: PendingWebhook] = [:]

    public init() {}

    public mutating func offer(_ pending: PendingWebhook, for meeting: String) {
        offers[meeting] = pending
    }

    public mutating func approve(_ meeting: String) -> PendingWebhook? {
        offers.removeValue(forKey: meeting)
    }

    public mutating func dismiss(_ meeting: String) {
        offers.removeValue(forKey: meeting)
    }
}

public enum WebhookDelivery {
    public static func deliver(_ approved: PendingWebhook?, via send: (PendingWebhook) async throws -> Void) async throws -> Bool {
        guard let approved else { return false }
        try await send(approved)
        return true
    }
}
