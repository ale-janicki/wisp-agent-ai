import Foundation

/// D15: with Telegram configured a message never falls back to a local session; it waits for the bot.
public enum DeliveryRoute: Equatable, Sendable {
    case local
    case telegram
    case hold(reason: String)
}

public enum DeliveryPolicy {
    public static let defaultHoldReason = "o Telegram está fora do ar"

    public static func route(telegramConfigured: Bool, canSend: Bool, downReason: String?) -> DeliveryRoute {
        guard telegramConfigured else { return .local }
        return canSend ? .telegram : .hold(reason: downReason ?? defaultHoldReason)
    }
}

/// `thread` is nil until the conversation has a topic; `text` is the caption and `files` the staged attachment paths.
/// `failure` is the last error; with `retryAt` set the drain tries again then, without it the message waits for the user.
public struct HeldMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var conversationId: UUID
    public var thread: Int?
    public var text: String
    public var heldAt: Date
    public var files: [String]?
    public var failure: String?
    public var attempts: Int
    public var retryAt: Date?

    public var isFailed: Bool { failure != nil && retryAt == nil }

    public init(
        id: UUID = UUID(), conversationId: UUID, thread: Int?, text: String, heldAt: Date = Date(), files: [String]? = nil
    ) {
        self.id = id
        self.conversationId = conversationId
        self.thread = thread
        self.text = text
        self.heldAt = heldAt
        self.files = files
        self.attempts = 0
    }

    private enum CodingKeys: String, CodingKey {
        case id, conversationId, thread, text, heldAt, files, failure, attempts, retryAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        conversationId = try container.decode(UUID.self, forKey: .conversationId)
        thread = try container.decodeIfPresent(Int.self, forKey: .thread)
        text = try container.decode(String.self, forKey: .text)
        heldAt = try container.decode(Date.self, forKey: .heldAt)
        files = try container.decodeIfPresent([String].self, forKey: .files)
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
        attempts = try container.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
        retryAt = try container.decodeIfPresent(Date.self, forKey: .retryAt)
    }
}

public enum HeldMark: Equatable, Sendable {
    case queued
    case sending
    case failed(String, canRetry: Bool)
}

/// What the drain does next. Pure: the app owns the clock, the bot status and the outbox file.
public enum OutboxPlan {
    public static let backoff: [TimeInterval] = [10, 30, 60]
    public static let poll: TimeInterval = 10
    public static let notConfigured = "Telegram não está configurado"
    public static let blockedSentence = "uma mensagem anterior não foi enviada; as seguintes esperam por ela"

    /// Only the oldest message of each conversation can go, so nothing overtakes within a conversation.
    private static func heads(_ all: [HeldMessage]) -> [HeldMessage] {
        var seen = Set<UUID>()
        return all.filter { seen.insert($0.conversationId).inserted }
    }

    public static func next(_ all: [HeldMessage], now: Date) -> HeldMessage? {
        heads(all).first { !$0.isFailed && ($0.retryAt ?? .distantPast) <= now }
    }

    public static func hasWork(_ all: [HeldMessage]) -> Bool {
        heads(all).contains { !$0.isFailed }
    }

    public static func failed(_ m: HeldMessage, sentence: String, now: Date, retry: Bool) -> HeldMessage {
        var next = m
        next.attempts += 1
        next.failure = sentence
        next.retryAt = retry && next.attempts <= backoff.count ? now.addingTimeInterval(backoff[next.attempts - 1]) : nil
        return next
    }

    public static func retried(_ m: HeldMessage) -> HeldMessage {
        var next = m
        next.failure = nil
        next.attempts = 0
        next.retryAt = nil
        return next
    }

    /// Seconds until the drain should look again: the poll, or sooner when a retry is due.
    public static func pause(_ all: [HeldMessage], now: Date) -> TimeInterval {
        let due = heads(all).compactMap { $0.isFailed ? nil : $0.retryAt }.map { max(0, $0.timeIntervalSince(now)) }
        return ([poll] + due).min() ?? poll
    }

    public static func thread(_ m: HeldMessage, record: Int?, linked: Int?) -> Int? {
        m.thread ?? record ?? linked
    }

    public static func missingFile(_ m: HeldMessage, exists: (String) -> Bool) -> String? {
        (m.files ?? []).first { !exists($0) }.map { ($0 as NSString).lastPathComponent }
    }

    public static func mark(_ m: HeldMessage, telegramConfigured: Bool, inFlight: UUID?) -> HeldMark {
        guard telegramConfigured else { return .failed(notConfigured, canRetry: false) }
        if m.id == inFlight { return .sending }
        if m.isFailed, let failure = m.failure { return .failed(failure, canRetry: true) }
        return .queued
    }

    /// The line under a conversation that waits; nil when nothing needs explaining (it goes now, or only a failed one is left).
    public static func phaseReason(conversation: UUID, _ all: [HeldMessage], now: Date, botDown: String?) -> String? {
        let mine = all.filter { $0.conversationId == conversation }
        guard let head = mine.first else { return nil }
        if head.isFailed { return mine.count > 1 ? blockedSentence : nil }
        if let at = head.retryAt, at > now {
            return "\(head.failure ?? DeliveryPolicy.defaultHoldReason); tento de novo em \(Int(at.timeIntervalSince(now).rounded(.up))) s"
        }
        if let botDown { return "\(botDown); a mensagem sai quando o bot voltar" }
        return nil
    }
}

public enum OutboxError: Error, LocalizedError {
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let reason): "a fila do Telegram não pôde ser lida (\(reason)) e não vou sobrescrevê-la"
        }
    }
}

public final class Outbox: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var messages: [HeldMessage] = []
    private var unreadable: String?
    public private(set) var lastRecoveryNote: String?

    private var fileURL: URL { directory.appendingPathComponent("outbox.json") }
    private var badURL: URL { directory.appendingPathComponent("outbox.json.bad") }

    public init(directory: URL = ConversationStore.defaultDirectory) {
        self.directory = directory
        load()
    }

    public func all() -> [HeldMessage] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }

    public func append(_ m: HeldMessage) throws {
        try update { $0.append(m) }
    }

    public func remove(id: UUID) throws {
        try update { $0.removeAll { $0.id == id } }
    }

    /// Writes back a message the drain changed (failure, attempts, thread); an unknown id is a no-op.
    public func replace(_ m: HeldMessage) throws {
        try update { list in
            if let index = list.firstIndex(where: { $0.id == m.id }) { list[index] = m }
        }
    }

    /// Counts a failed attempt on the stored copy, so a thread assigned during the attempt is kept; nil for an unknown id.
    @discardableResult
    public func fail(id: UUID, sentence: String, now: Date, retry: Bool) throws -> HeldMessage? {
        var failed: HeldMessage?
        try update { list in
            guard let index = list.firstIndex(where: { $0.id == id }) else { return }
            list[index] = OutboxPlan.failed(list[index], sentence: sentence, now: now, retry: retry)
            failed = list[index]
        }
        return failed
    }

    /// Once the first held message of a conversation creates its topic, the rest of that conversation goes there too.
    public func assignThread(_ thread: Int, conversationId: UUID) throws {
        try update { list in
            for index in list.indices where list[index].conversationId == conversationId && list[index].thread == nil {
                list[index].thread = thread
            }
        }
    }

    private func update(_ change: (inout [HeldMessage]) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        if let unreadable { throw OutboxError.unreadable(unreadable) }
        var next = messages
        change(&next)
        next = Self.sorted(next)
        try persist(next)
        messages = next
    }

    private static func sorted(_ list: [HeldMessage]) -> [HeldMessage] {
        list.enumerated().sorted { a, b in
            a.element.heldAt == b.element.heldAt ? a.offset < b.offset : a.element.heldAt < b.element.heldAt
        }.map(\.element)
    }

    private func persist(_ list: [HeldMessage]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: fileURL, options: .atomic)
    }

    /// Only a decode error moves the file aside; a read error leaves it and refuses every write.
    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            unreadable = error.localizedDescription
            lastRecoveryNote = "não consegui ler a fila do Telegram em \(fileURL.path): \(error.localizedDescription)"
            return
        }
        do {
            messages = Self.sorted(try JSONDecoder().decode([HeldMessage].self, from: data))
        } catch {
            if fm.fileExists(atPath: badURL.path) {
                let stamp = Int(Date().timeIntervalSince1970 * 1000)
                try? fm.moveItem(at: badURL, to: directory.appendingPathComponent("outbox.json.bad-\(stamp)"))
            }
            try? fm.removeItem(at: badURL)
            try? fm.moveItem(at: fileURL, to: badURL)
            messages = []
            lastRecoveryNote = "a fila do Telegram estava corrompida; guardei uma cópia em \(badURL.path)"
        }
    }
}
