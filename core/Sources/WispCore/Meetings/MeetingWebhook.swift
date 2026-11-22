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

    public init(url: URL, body: Data) {
        self.url = url
        self.body = body
    }

    public var host: String { url.host ?? url.absoluteString }

    public var sizeText: String {
        body.count < 1024 ? "\(body.count) B" : String(format: "%.1f KB", Double(body.count) / 1024)
    }
}

public enum MeetingWebhook {
    public static let maximumURLLength = 2048
    public static let noteLimit = 500_000

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

    public static func payload(
        title: String, startedAt: Date, durationSeconds: Double, note: String, metrics: MeetingMetrics?
    ) throws -> Data {
        struct Body: Encodable {
            var event: String
            var title: String
            var startedAt: Date
            var durationSeconds: Double
            var note: String
            var metrics: MeetingMetrics?
            var actionItems: [ActionItem]

            enum CodingKeys: String, CodingKey {
                case event, title, note, metrics
                case startedAt = "started_at"
                case durationSeconds = "duration_s"
                case actionItems = "action_items"
            }
        }
        let withoutTranscript = note.components(separatedBy: "\n## Transcrição").first ?? note
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Body(
            event: "meeting.finished", title: title, startedAt: startedAt, durationSeconds: durationSeconds,
            note: String(withoutTranscript.prefix(noteLimit)), metrics: metrics, actionItems: actionItems(in: note)
        ))
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
        return bytes[0] & 0xE0 == 0x20
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
