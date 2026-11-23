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
    public var conversation: String?

    public var id: Int { thread }

    public init(
        thread: Int,
        name: String,
        sessionId: String,
        cwd: String,
        turns: Int = 0,
        lastUsed: Date? = nil,
        host: String? = nil,
        fixed: Bool = false,
        conversation: String? = nil
    ) {
        self.conversation = conversation?.lowercased()
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
        case thread, name, cwd, turns, host, fixed, conversation
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
        conversation = try container.decodeIfPresent(String.self, forKey: .conversation).flatMap { $0.isEmpty ? nil : $0.lowercased() }
    }

    public func matches(sessionId: String?, conversation id: UUID?) -> Bool {
        if let conversation, let id, conversation == id.uuidString.lowercased() { return true }
        guard let sessionId, !sessionId.isEmpty else { return false }
        return self.sessionId == sessionId
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
    public var conversation: String?
    public var turnAt: String?

    public init(
        thread: Int, user: String, reply: String, files: [String] = [], conversation: String? = nil, turnAt: String? = nil
    ) {
        self.turnAt = turnAt
        self.thread = thread
        self.user = user
        self.reply = reply
        self.files = files
        self.conversation = conversation
    }

    public var payload: Data {
        var body: [String: Any] = ["thread": thread, "user": user, "reply": reply]
        if !files.isEmpty { body["arquivos"] = files }
        if let conversation, !conversation.isEmpty { body["conversation"] = conversation }
        if let turnAt, !turnAt.isEmpty { body["turn_at"] = turnAt }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

public struct TelegramEntry: Identifiable, Sendable, Equatable {
    public var topic: TelegramTopic
    public var record: ConversationRecord?

    public var id: Int { topic.thread }
    public var pinKey: String { TelegramTopics.pinKey(thread: topic.thread) }
}

public struct ConversationSections: Sendable, Equatable {
    public var wisp: [ConversationRecord]
    public var telegram: [TelegramEntry]
}

/// One row of the conversation search: an open Local conversation, a Telegram topic, or a closed conversation.
public enum ConversationHit: Identifiable, Sendable, Equatable {
    case local(ConversationRecord)
    case topic(TelegramEntry)
    case closed(ConversationRecord)

    public var id: String {
        switch self {
        case .local(let record), .closed(let record): record.id.uuidString.lowercased()
        case .topic(let entry): TelegramTopics.pinKey(thread: entry.topic.thread)
        }
    }
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

    public static func mirror(
        sessionId: String?, conversation: UUID? = nil, topics: [TelegramTopic]?, user: String, reply: String,
        files: [String] = [], turnAt: String? = nil
    ) -> TelegramPost? {
        guard let topic = topic(forSession: sessionId, conversation: conversation, in: topics),
              !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return TelegramPost(
            thread: topic.thread, user: user, reply: reply, files: files, conversation: conversation?.uuidString.lowercased(),
            turnAt: turnAt)
    }

    public static func topic(forSession sessionId: String?, conversation: UUID? = nil, in topics: [TelegramTopic]?) -> TelegramTopic? {
        guard let topics else { return nil }
        if let conversation, let hit = topics.first(where: { $0.matches(sessionId: nil, conversation: conversation) }) { return hit }
        return topics.filter { $0.matches(sessionId: sessionId, conversation: nil) }
            .max { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
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

    /// Pin identifiers: a Local conversation by its own id (the app owns it), a Telegram topic by its thread
    /// (the bot keeps it across relaunches and rewrites of its conversations file, while the linked record can change).
    public static func pinKey(conversation id: UUID) -> String { id.uuidString.lowercased() }
    public static func pinKey(thread: Int) -> String { "tg:\(thread)" }

    /// Pinned items first, in pin order; everything else keeps its order. Pins with no item are ignored.
    public static func pinnedFirst<Item>(_ items: [Item], pins: [String], key: (Item) -> String) -> [Item] {
        guard !pins.isEmpty else { return items }
        var rank: [String: Int] = [:]
        for (index, pin) in pins.enumerated() where rank[pin] == nil { rank[pin] = index }
        let pinned = items.filter { rank[key($0)] != nil }.sorted { rank[key($0)]! < rank[key($1)]! }
        return pinned + items.filter { rank[key($0)] == nil }
    }

    /// The result of a drag in the Telegram list: a new saved topic order, or a new pin order, never both.
    public struct DragResult: Equatable, Sendable {
        public var order: [Int]
        public var pins: [String]
    }

    /// Applies a drag over the shown (pinned-first) thread ids. `pinnedCount` is the size of the pinned block.
    /// Inside the unpinned block only the unpinned ids move in `order`, pinned ids keep their slots there;
    /// inside the pinned block only the Telegram pins are reordered; a drop across the boundary changes nothing (nil).
    public static func applyDrag(shown: [Int], final: [Int], pinnedCount: Int, order: [Int], pins: [String]) -> DragResult? {
        guard final != shown, final.count == shown.count, Set(final) == Set(shown),
              (0...shown.count).contains(pinnedCount),
              Set(final.prefix(pinnedCount)) == Set(shown.prefix(pinnedCount)) else { return nil }
        if Array(final.prefix(pinnedCount)) != Array(shown.prefix(pinnedCount)) {
            let moved = final.prefix(pinnedCount).map { pinKey(thread: $0) }
            let members = Set(moved)
            var queue = moved[...]
            let newPins = pins.map { members.contains($0) ? queue.popFirst() ?? $0 : $0 }
            return DragResult(order: order, pins: newPins)
        }
        let unpinned = Array(final.dropFirst(pinnedCount))
        let members = Set(unpinned)
        var seen = Set<Int>()
        let saved = order.filter { seen.insert($0).inserted }
        let fresh = shown.dropFirst(pinnedCount).filter { !seen.contains($0) }
        var queue = unpinned[...]
        let merged = (fresh + saved).map { members.contains($0) ? queue.popFirst() ?? $0 : $0 }
        return DragResult(order: merged, pins: pins)
    }

    /// Case- and diacritic-insensitive containment of `query` in `text`.
    public static func matches(_ text: String?, query: String) -> Bool {
        guard let text else { return false }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return text.range(of: query, options: options) != nil
    }

    /// Search over the open conversations (in their section order: Local, then Telegram) followed by the closed
    /// ones, newest `closedAt` first. A blank query finds nothing, so closed conversations are never listed without one.
    public static func search(
        query: String, sections: ConversationSections, allRecords: [ConversationRecord],
        preview: (ConversationRecord) -> String?, topicPreview: (TelegramEntry) -> String?
    ) -> [ConversationHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let local = sections.wisp
            .filter { matches($0.title, query: query) || matches(preview($0), query: query) }
            .map(ConversationHit.local)
        let topics = sections.telegram
            .filter {
                matches($0.topic.name, query: query) || matches($0.record?.title, query: query)
                    || matches(topicPreview($0), query: query)
            }
            .map(ConversationHit.topic)
        let closed = allRecords.filter { $0.isClosed && (matches($0.title, query: query) || matches(preview($0), query: query)) }
            .sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
            .map(ConversationHit.closed)
        return local + topics + closed
    }

    public static func sections(
        allRecords: [ConversationRecord], topics: [TelegramTopic]?, order: [Int] = [], pins: [String] = []
    ) -> ConversationSections {
        sections(records: allRecords.filter { !$0.isClosed }, topics: topics, order: order, pins: pins)
    }

    public static func sections(
        records: [ConversationRecord], topics: [TelegramTopic]?, order: [Int] = [], pins: [String] = []
    ) -> ConversationSections {
        guard let topics else {
            return ConversationSections(wisp: pinnedFirst(records, pins: pins) { pinKey(conversation: $0.id) }, telegram: [])
        }
        var linked: [Int: ConversationRecord] = [:]
        var taken = Set<UUID>()
        for topic in topics {
            let byConversation = records.filter { topic.matches(sessionId: nil, conversation: $0.id) }
            let bySession = records.filter { topic.matches(sessionId: $0.sessionId, conversation: nil) }
            guard let best = byConversation.max(by: { $0.updatedAt < $1.updatedAt })
                ?? bySession.max(by: { $0.updatedAt < $1.updatedAt }) else { continue }
            linked[topic.thread] = best
            taken.formUnion((byConversation + bySession).map(\.id))
        }
        return ConversationSections(
            wisp: pinnedFirst(records.filter { !taken.contains($0.id) }, pins: pins) { pinKey(conversation: $0.id) },
            telegram: pinnedFirst(
                ordered(topics, saved: order).map { TelegramEntry(topic: $0, record: linked[$0.thread]) }, pins: pins, key: \.pinKey)
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

    public func shareCommand(session: String, cwd: String, name: String, conversation: String) -> String? {
        guard let share, !share.isEmpty else { return nil }
        let template = share.contains("{conversation}") || !share.contains(" compartilhar ")
            ? share : share + " --conversation={conversation}"
        return CommandTemplate.fill(template, ["session": session, "cwd": cwd, "name": name, "conversation": conversation])
    }

    public var canShare: Bool { !(share ?? "").isEmpty }
    public var canPost: Bool { !(post ?? "").isEmpty }
}
