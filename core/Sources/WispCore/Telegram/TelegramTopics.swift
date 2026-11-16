import Foundation

public struct TelegramTopic: Decodable, Identifiable, Sendable, Equatable {
    public var thread: Int
    public var name: String
    public var sessionId: String
    public var cwd: String
    public var turns: Int
    public var lastUsed: Date?

    public var id: Int { thread }

    public init(thread: Int, name: String, sessionId: String, cwd: String, turns: Int = 0, lastUsed: Date? = nil) {
        self.thread = thread
        self.name = name
        self.sessionId = sessionId
        self.cwd = cwd
        self.turns = turns
        self.lastUsed = lastUsed
    }

    private enum CodingKeys: String, CodingKey {
        case thread, name, cwd, turns
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
    }
}

public struct TelegramStatus: Decodable, Sendable, Equatable {
    public var up: Bool
    public var host: String?
    public var state: String?

    public init(up: Bool, host: String? = nil, state: String? = nil) {
        self.up = up
        self.host = host
        self.state = state
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

    public static func topicName(from message: String) -> String {
        let line = message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > nameLimit else { return line }
        return String(line.prefix(nameLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    public static func sections(records: [ConversationRecord], topics: [TelegramTopic]?) -> ConversationSections {
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
            telegram: topics.map { TelegramEntry(topic: $0, record: linked[$0.thread]) }
        )
    }
}

public struct TelegramBlock: Codable, Sendable, Equatable {
    public var status: String?
    public var list: String?
    public var create: String?
    public var send: String?
    public var close: String?

    public init(status: String? = nil, list: String? = nil, create: String? = nil, send: String? = nil, close: String? = nil) {
        self.status = status
        self.list = list
        self.create = create
        self.send = send
        self.close = close
    }

    public var isComplete: Bool {
        [status, list, create, send, close].allSatisfy { !($0 ?? "").isEmpty }
    }
}
