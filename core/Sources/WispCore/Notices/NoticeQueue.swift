import Foundation

public enum NoticeKind: String, Codable, CaseIterable, Sendable {
    case reply, telegram, reminder, outbox, update
}

public enum NoticeTarget: Hashable, Sendable {
    case conversation(UUID)
    case topic(Int)
    case reminders
    case update

    var sourceId: String {
        switch self {
        case .conversation(let id): "conversation:\(id.uuidString)"
        case .topic(let thread): "topic:\(thread)"
        case .reminders: "reminders"
        case .update: "update"
        }
    }
}

public struct Notice: Identifiable, Equatable, Sendable {
    public enum Tone: Sendable, Equatable { case normal, warning, alert }

    public var sourceId: String
    public var kind: NoticeKind
    public var title: String
    public var preview: String
    public var time: Date
    public var target: NoticeTarget
    public var tone: Tone

    public var id: String { sourceId }

    public init(
        sourceId: String? = nil, kind: NoticeKind, title: String, preview: String, time: Date, target: NoticeTarget,
        tone: Tone = .normal
    ) {
        self.sourceId = sourceId ?? target.sourceId
        self.kind = kind
        self.title = title
        self.preview = preview
        self.time = time
        self.target = target
        self.tone = tone
    }
}

public struct NoticeSettings: Codable, Equatable, Sendable {
    public var reply = true
    public var telegram = true
    public var reminder = true
    public var outbox = true
    public var update = true
    public var doNotDisturb = false

    public init() {}

    public subscript(kind: NoticeKind) -> Bool {
        get {
            switch kind {
            case .reply: reply
            case .telegram: telegram
            case .reminder: reminder
            case .outbox: outbox
            case .update: update
            }
        }
        set {
            switch kind {
            case .reply: reply = newValue
            case .telegram: telegram = newValue
            case .reminder: reminder = newValue
            case .outbox: outbox = newValue
            case .update: update = newValue
            }
        }
    }

    public func allows(_ kind: NoticeKind) -> Bool { !doNotDisturb && self[kind] }

    private enum CodingKeys: String, CodingKey { case reply, telegram, reminder, outbox, update, doNotDisturb }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reply = try container.decodeIfPresent(Bool.self, forKey: .reply) ?? true
        telegram = try container.decodeIfPresent(Bool.self, forKey: .telegram) ?? true
        reminder = try container.decodeIfPresent(Bool.self, forKey: .reminder) ?? true
        outbox = try container.decodeIfPresent(Bool.self, forKey: .outbox) ?? true
        update = try container.decodeIfPresent(Bool.self, forKey: .update) ?? true
        doNotDisturb = try container.decodeIfPresent(Bool.self, forKey: .doNotDisturb) ?? false
    }
}

public struct NoticeQueue: Equatable, Sendable {
    public static let showFor: TimeInterval = 6
    public static let afterHover: TimeInterval = 2
    public static let maxPending = 3

    public enum Outcome: Equatable, Sendable { case shown, queued, updated, suppressed }

    public private(set) var current: Notice?
    public private(set) var pending: [Notice] = []
    public private(set) var hovering = false
    private var remaining: TimeInterval = 0
    private var runningSince: Date?

    public init() {}

    public var badge: Int { pending.count }

    public var deadline: Date? {
        guard current != nil, let runningSince else { return nil }
        return runningSince.addingTimeInterval(remaining)
    }

    @discardableResult
    public mutating func offer(_ notice: Notice, settings: NoticeSettings, visible: Set<NoticeTarget>, now: Date) -> Outcome {
        guard settings.allows(notice.kind), !visible.contains(notice.target) else { return .suppressed }
        if current?.sourceId == notice.sourceId {
            current = notice
            restart(now: now)
            return .updated
        }
        if let index = pending.firstIndex(where: { $0.sourceId == notice.sourceId }) {
            pending[index] = notice
            return .updated
        }
        guard current != nil else {
            current = notice
            restart(now: now)
            return .shown
        }
        pending.append(notice)
        if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
        return .queued
    }

    public mutating func hover(_ on: Bool, now: Date) {
        guard on != hovering, current != nil || !on else { return }
        hovering = on
        if on {
            if let deadline { remaining = max(0, deadline.timeIntervalSince(now)) }
            runningSince = nil
        } else {
            remaining = max(remaining, Self.afterHover)
            runningSince = now
        }
    }

    @discardableResult
    public mutating func expire(now: Date) -> Bool {
        guard let deadline, now >= deadline else { return false }
        advance(now: now)
        return true
    }

    public mutating func dismiss(now: Date) {
        advance(now: now)
    }

    public mutating func take(now: Date) -> Notice? {
        let taken = current
        advance(now: now)
        return taken
    }

    public mutating func prune(settings: NoticeSettings, visible: Set<NoticeTarget>, now: Date) {
        let keep = { (notice: Notice) in settings.allows(notice.kind) && !visible.contains(notice.target) }
        pending.removeAll { !keep($0) }
        if let current, !keep(current) { advance(now: now) }
    }

    private mutating func advance(now: Date) {
        current = pending.isEmpty ? nil : pending.removeFirst()
        if current == nil {
            runningSince = nil
            remaining = 0
            hovering = false
        } else {
            restart(now: now)
        }
    }

    private mutating func restart(now: Date) {
        remaining = Self.showFor
        runningSince = hovering ? nil : now
    }
}

public struct NoticeBaselines: Equatable, Sendable {
    public private(set) var alerts: [AlertItem]?
    public private(set) var topics: [TelegramTopic]?

    public init() {}

    private static func alertsOn(_ settings: NoticeSettings) -> Bool { settings.allows(.reminder) }
    private static func topicsOn(_ settings: NoticeSettings) -> Bool { settings.allows(.telegram) || settings.allows(.reply) }

    public mutating func alertsRead(_ items: [AlertItem], settings: NoticeSettings) -> [AlertItem] {
        guard Self.alertsOn(settings) else {
            alerts = nil
            return []
        }
        defer { alerts = items }
        return Notices.newAlerts(old: alerts, new: items)
    }

    public mutating func topicsRead(_ list: [TelegramTopic], following: Int?, wispThreads: Set<Int>, settings: NoticeSettings) -> [TelegramTopic] {
        guard Self.topicsOn(settings) else {
            topics = nil
            return []
        }
        defer { topics = list }
        return Notices.topicNews(old: topics, new: list, following: following, wispThreads: wispThreads)
    }

    public mutating func settingsChanged(_ settings: NoticeSettings) {
        if !Self.alertsOn(settings) { alerts = nil }
        if !Self.topicsOn(settings) { topics = nil }
    }
}

public enum Notices {
    public static let previewLimit = 140
    public static let heldLongEnough: TimeInterval = 30

    public static func newAlerts(old: [AlertItem]?, new: [AlertItem]) -> [AlertItem] {
        guard let old else { return [] }
        let known = Set(old.map(\.id))
        return new.filter { !known.contains($0.id) }
    }

    public static func topicNews(old: [TelegramTopic]?, new: [TelegramTopic], following: Int?, wispThreads: Set<Int>) -> [TelegramTopic] {
        guard let old else { return [] }
        let before = Dictionary(old.map { ($0.thread, $0) }, uniquingKeysWith: { first, _ in first })
        return new.filter { topic in
            guard topic.thread != following else { return false }
            guard let previous = before[topic.thread] else { return !wispThreads.contains(topic.thread) }
            return topic.turns > previous.turns || (topic.lastUsed ?? .distantPast) > (previous.lastUsed ?? .distantPast)
        }
    }

    public static func outboxSentIsNews(_ message: HeldMessage, now: Date) -> Bool {
        message.attempts > 0 || now.timeIntervalSince(message.heldAt) >= heldLongEnough
    }

    public static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > previewLimit else { return line }
        return String(line.prefix(previewLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
