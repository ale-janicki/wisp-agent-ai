import Foundation

public struct TelegramTopic: Decodable, Identifiable, Sendable, Equatable {
    public var thread: Int
    public var name: String
    public var sessionId: String
    public var cwd: String
    public var turns: Int
    public var lastUsed: Date?
    public var host: String?
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

public struct TelegramShared: Decodable, Sendable, Equatable {
    public var thread: Int
    public var name: String
    public var sessionId: String

    private enum CodingKeys: String, CodingKey {
        case thread, name
        case sessionId = "session_id"
    }
}

public struct TelegramPost: Sendable, Equatable {
    public var thread: Int
    public var user: String
    public var reply: String
    public var files: [String] = []

    public init(thread: Int, user: String, reply: String, files: [String] = []) {
        self.thread = thread
        self.user = user
        self.reply = reply
        self.files = files
    }

    public var payload: Data {
        var body: [String: Any] = ["thread": thread, "user": user, "reply": reply]
        if !files.isEmpty { body["arquivos"] = files }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
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
    public static func parseTopics(_ data: Data) throws -> [TelegramTopic] {
        try JSONDecoder().decode([TelegramTopic].self, from: data)
    }

    public static func parseStatus(_ data: Data) throws -> TelegramStatus {
        try JSONDecoder().decode(TelegramStatus.self, from: data)
    }

    public static func parseShared(_ data: Data) throws -> TelegramShared {
        try JSONDecoder().decode(TelegramShared.self, from: data)
    }

    public static func mirror(sessionId: String?, topics: [TelegramTopic]?, user: String, reply: String, files: [String] = []) -> TelegramPost? {
        guard let topic = topic(forSession: sessionId, in: topics),
              !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TelegramPost(thread: topic.thread, user: user, reply: reply, files: files)
    }

    public static func topic(forSession sessionId: String?, in topics: [TelegramTopic]?) -> TelegramTopic? {
        guard let sessionId, let topics else { return nil }
        return topics.first { $0.sessionId == sessionId }
    }

    static func pinned(_ topics: [TelegramTopic]) -> [TelegramTopic] {
        topics.filter(\.fixed).sorted { $0.thread < $1.thread } + topics.filter { !$0.fixed }
    }

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
        let sessions = Set(topics.map(\.sessionId))
        var linked: [String: ConversationRecord] = [:]
        for record in records {
            guard let sessionId = record.sessionId, sessions.contains(sessionId) else { continue }
            if let current = linked[sessionId], current.updatedAt >= record.updatedAt { continue }
            linked[sessionId] = record
        }
        return ConversationSections(
            wisp: records.filter { record in record.sessionId.map { !sessions.contains($0) } ?? true },
            telegram: ordered(topics, saved: order).map { TelegramEntry(topic: $0, record: linked[$0.sessionId]) }
        )
    }
}

public struct TelegramBlock: Codable, Sendable, Equatable {
    public var status: String?
    public var list: String?
    public var share: String?
    public var post: String?
    public var close: String?
    public var attachments: String?

    public init(
        status: String? = nil, list: String? = nil, share: String? = nil, post: String? = nil,
        close: String? = nil, attachments: String? = nil
    ) {
        self.status = status
        self.list = list
        self.share = share
        self.post = post
        self.close = close
        self.attachments = attachments
    }

    public var isComplete: Bool {
        [status, list, close].allSatisfy { !($0 ?? "").isEmpty }
    }

    public func derivingActions() -> TelegramBlock {
        let suffix = " topic listar --json"
        guard let list, list.hasSuffix(suffix) else { return self }
        let bin = String(list.dropLast(suffix.count))
        guard !bin.trimmingCharacters(in: .whitespaces).isEmpty else { return self }
        var derived = self
        if (share ?? "").isEmpty {
            derived.share = "\(bin) topic compartilhar --session={session} --cwd={cwd} --nome={name} --json"
        }
        if (post ?? "").isEmpty { derived.post = "\(bin) topic postar --json" }
        return derived
    }

    public var binary: String? {
        let suffix = " topic listar --json"
        guard let list, list.hasSuffix(suffix) else { return nil }
        var bin = String(list.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        if bin.count >= 2, let first = bin.first, first == bin.last, first == "\"" || first == "'" {
            bin = String(bin.dropFirst().dropLast())
        }
        return bin.isEmpty ? nil : bin
    }

    public var canShare: Bool { !(share ?? "").isEmpty }
    public var canPost: Bool { !(post ?? "").isEmpty }
}
