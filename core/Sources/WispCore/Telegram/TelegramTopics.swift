import Foundation

public struct TelegramTopic: Decodable, Identifiable, Sendable, Equatable {
    public var thread: Int
    public var name: String
    public var sessionId: String
    public var cwd: String
    public var turns: Int
    public var lastUsed: Date?
    public var host: String?
    /// Geral and Journals: the bot refuses to close them.
    public var fixed: Bool

    public var id: Int { thread }

    public init(
        thread: Int,
        name: String,
        sessionId: String,
        cwd: String,
        turns: Int = 0,
        lastUsed: Date? = nil,
        host: String? = nil,
        fixed: Bool = false
    ) {
        self.thread = thread
        self.name = name
        self.sessionId = sessionId
        self.cwd = cwd
        self.turns = turns
        self.lastUsed = lastUsed
        self.host = host
        self.fixed = fixed
    }

    private enum CodingKeys: String, CodingKey {
        case thread, name, cwd, turns, host, fixed
        case sessionId = "session_id"
        case lastUsed = "last_used"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thread = try container.decode(Int.self, forKey: .thread)
        name = try container.decode(String.self, forKey: .name)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd) ?? "~"
        turns = try container.decodeIfPresent(Int.self, forKey: .turns) ?? 0
        lastUsed = try container.decodeIfPresent(Double.self, forKey: .lastUsed).map(Date.init(timeIntervalSince1970:))
        host = try container.decodeIfPresent(String.self, forKey: .host)
        fixed = try container.decodeIfPresent(Bool.self, forKey: .fixed) ?? false
    }
}

public enum TelegramReading: Sendable, Equatable {
    case here
    case elsewhere(String)
    case nobody
}

public enum TelegramClaimNeed: Sendable, Equatable {
    case none
    case refresh
    case handOff(String)
}

public struct TelegramStatus: Decodable, Sendable, Equatable {
    public var up: Bool
    public var host: String?
    public var state: String?
    public var reader: String?
    public var claim: String?

    public init(up: Bool, host: String? = nil, state: String? = nil, reader: String? = nil, claim: String? = nil) {
        self.up = up
        self.host = host
        self.state = state
        self.reader = reader
        self.claim = claim
    }

    public var reading: TelegramReading {
        if up { return .here }
        guard let reader, !reader.isEmpty, reader != host else { return .nobody }
        return .elsewhere(reader)
    }

    public var claimNeed: TelegramClaimNeed {
        switch reading {
        case .elsewhere(let reader): .handOff(reader)
        case .nobody: .none
        case .here:
            if let host, !host.isEmpty, claim != host { .refresh } else { .none }
        }
    }
}

public struct TelegramCreated: Decodable, Sendable, Equatable {
    public var thread: Int
    public var sessionId: String
    public var cwd: String

    private enum CodingKeys: String, CodingKey {
        case thread, cwd
        case sessionId = "session_id"
    }
}

public struct TelegramClaim: Decodable, Sendable, Equatable {
    public var ok: Bool
    public var reader: String?
    public var waitedSeconds: Double?

    public init(ok: Bool, reader: String? = nil, waitedSeconds: Double? = nil) {
        self.ok = ok
        self.reader = reader
        self.waitedSeconds = waitedSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case ok, reader
        case waitedSeconds = "waited_s"
    }
}

public struct TelegramEntry: Identifiable, Sendable, Equatable {
    public var topic: TelegramTopic
    public var record: ConversationRecord?

    public var id: Int { topic.thread }
}

public struct ConversationSections: Sendable, Equatable {
    public var wisp: [ConversationRecord]
    public var telegram: [TelegramEntry]
}

public enum TelegramTopics {
    public static let nameLimit = 40

    public static func parseTopics(_ data: Data) throws -> [TelegramTopic] {
        try JSONDecoder().decode([TelegramTopic].self, from: data)
    }

    public static func parseStatus(_ data: Data) throws -> TelegramStatus {
        try JSONDecoder().decode(TelegramStatus.self, from: data)
    }

    public static func parseCreated(_ data: Data) throws -> TelegramCreated {
        try JSONDecoder().decode(TelegramCreated.self, from: data)
    }

    public static func parseClaim(_ data: Data) throws -> TelegramClaim {
        try JSONDecoder().decode(TelegramClaim.self, from: data)
    }

    public static func claimFailure(_ message: String) -> String {
        let prefix = "Wisp-topico: "
        return message.hasPrefix(prefix) ? String(message.dropFirst(prefix.count)) : message
    }

    public static func hostName(_ host: String) -> String {
        switch host.lowercased() {
        case "pc": "PC"
        case "mac": "Mac"
        default: host
        }
    }

    public static func topicName(from message: String) -> String {
        let line = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > nameLimit else { return line }
        return String(line.prefix(nameLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Geral then Journals first (by thread), the rest in the order the CLI gave (last use).
    static func pinned(_ topics: [TelegramTopic]) -> [TelegramTopic] {
        topics.filter(\.fixed).sorted { $0.thread < $1.thread } + topics.filter { !$0.fixed }
    }

    /// Without a saved order: `pinned`. With one: threads it does not know (new topics) on top by last use,
    /// then the saved ones in their saved order; saved ids no longer listed are skipped.
    static func ordered(_ topics: [TelegramTopic], saved: [Int]) -> [TelegramTopic] {
        guard !saved.isEmpty else { return pinned(topics) }
        let byThread = Dictionary(topics.map { ($0.thread, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<Int>()
        let kept = saved.compactMap { thread in seen.insert(thread).inserted ? byThread[thread] : nil }
        let fresh = topics.filter { !seen.contains($0.thread) }.sorted {
            ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast)
        }
        return fresh + kept
    }

    public static func sections(records: [ConversationRecord], topics: [TelegramTopic]?, order: [Int] = []) -> ConversationSections {
        guard let topics else { return ConversationSections(wisp: records, telegram: []) }
        let threads = Set(topics.map(\.thread))
        var linked: [Int: ConversationRecord] = [:]
        for record in records {
            guard let thread = record.telegramThread, threads.contains(thread) else { continue }
            if let current = linked[thread], current.updatedAt >= record.updatedAt { continue }
            linked[thread] = record
        }
        return ConversationSections(
            wisp: records.filter { record in record.telegramThread.map { !threads.contains($0) } ?? true },
            telegram: ordered(topics, saved: order).map { TelegramEntry(topic: $0, record: linked[$0.thread]) }
        )
    }
}

public struct TelegramBlock: Codable, Sendable, Equatable {
    public var status: String?
    public var list: String?
    public var create: String?
    public var send: String?
    public var close: String?
    public var claim: String?
    /// Folder the bot accepts attachments from (`<folder>/<yyyy-MM-dd>/…`); Wisp copies picked files there.
    public var attachments: String?

    /// `send` passes files through an optional `{anexos}` (repeated `--anexo 'path'`); without it, text only.
    public var sendsAttachments: Bool { (send ?? "").contains("{anexos}") }

    public init(
        status: String? = nil, list: String? = nil, create: String? = nil, send: String? = nil,
        close: String? = nil, claim: String? = nil, attachments: String? = nil
    ) {
        self.status = status
        self.list = list
        self.create = create
        self.send = send
        self.close = close
        self.claim = claim
        self.attachments = attachments
    }

    public var isComplete: Bool {
        [status, list, create, send, close].allSatisfy { !($0 ?? "").isEmpty }
    }
}
