import Foundation

public struct ConversationRecord: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var sessionId: String?
    public var title: String
    public var updatedAt: Date
    public var telegramThread: Int?
    public var cwd: String?
    public var lastPreview: String?
    public var lastFrom: PreviewSide?
    public var titleGenerated: Bool
    public var awayOnPhone: Bool
    public var closedAt: Date?
    public var closedFrom: String?

    public var isClosed: Bool { closedAt != nil }

    public init(
        id: UUID, sessionId: String?, title: String, updatedAt: Date,
        telegramThread: Int? = nil, cwd: String? = nil,
        lastPreview: String? = nil, lastFrom: PreviewSide? = nil, titleGenerated: Bool = false,
        awayOnPhone: Bool = false, closedAt: Date? = nil, closedFrom: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.title = title
        self.updatedAt = updatedAt
        self.telegramThread = telegramThread
        self.cwd = cwd
        self.lastPreview = lastPreview
        self.lastFrom = lastFrom
        self.titleGenerated = titleGenerated
        self.awayOnPhone = awayOnPhone
        self.closedAt = closedAt
        self.closedFrom = closedFrom
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        title = try c.decode(String.self, forKey: .title)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        telegramThread = try c.decodeIfPresent(Int.self, forKey: .telegramThread)
        cwd = try c.decodeIfPresent(String.self, forKey: .cwd)
        lastPreview = try c.decodeIfPresent(String.self, forKey: .lastPreview)
        lastFrom = try c.decodeIfPresent(PreviewSide.self, forKey: .lastFrom)
        titleGenerated = try c.decodeIfPresent(Bool.self, forKey: .titleGenerated) ?? false
        awayOnPhone = try c.decodeIfPresent(Bool.self, forKey: .awayOnPhone) ?? false
        if let at = try? c.decodeIfPresent(Date.self, forKey: .closedAt) {
            closedAt = at
            closedFrom = try? c.decodeIfPresent(String.self, forKey: .closedFrom)
        }
    }
}

public final class ConversationStore: @unchecked Sendable {
    public static var defaultDirectory: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Wisp", isDirectory: true)
    }

    private let directory: URL
    private let lock = NSLock()
    private var records: [ConversationRecord] = []
    public private(set) var lastRecoveryNote: String?
    private var seenStamp: Date?

    private var fileURL: URL { directory.appendingPathComponent("conversations.json") }
    private var badURL: URL { directory.appendingPathComponent("conversations.json.bad") }

    public init(directory: URL = ConversationStore.defaultDirectory) {
        self.directory = directory
        load()
    }

    public func all() -> [ConversationRecord] {
        lock.lock()
        defer { lock.unlock() }
        reloadIfChanged()
        return sorted(records)
    }

    public func upsert(_ record: ConversationRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        try withFileLock {
            reloadIfChanged()
            var next = records
            if let index = next.firstIndex(where: { $0.id == record.id }) {
                next[index] = record
            } else {
                next.append(record)
            }
            try persist(next)
            records = next
        }
    }

    public func delete(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try withFileLock {
            reloadIfChanged()
            let next = records.filter { $0.id != id }
            try persist(next)
            records = next
        }
    }

    public func reopen(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        try withFileLock {
            reloadIfChanged()
            var next = records
            guard let index = next.firstIndex(where: { $0.id == id }), next[index].isClosed else { return }
            next[index].closedAt = nil
            next[index].closedFrom = nil
            try persist(next)
            records = next
        }
    }

    private var lockURL: URL { directory.appendingPathComponent("conversations.json.lock") }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func sorted(_ list: [ConversationRecord]) -> [ConversationRecord] {
        list.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func persist(_ list: [ConversationRecord]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, enc in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var container = enc.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sorted(list)).write(to: fileURL, options: .atomic)
        seenStamp = modificationStamp()
    }

    private func modificationStamp() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }

    private func reloadIfChanged() {
        guard modificationStamp() != seenStamp else { return }
        load()
    }

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        seenStamp = modificationStamp()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dec in
            let text = try dec.singleValueContainer().decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "Bad ISO8601 date: \(text)"))
        }
        do {
            let data = try Data(contentsOf: fileURL)
            records = try decoder.decode([ConversationRecord].self, from: data)
        } catch {
            try? fm.removeItem(at: badURL)
            try? fm.moveItem(at: fileURL, to: badURL)
            records = []
            lastRecoveryNote = "o índice de conversas estava corrompido; guardei uma cópia em \(badURL.path)"
        }
    }
}
