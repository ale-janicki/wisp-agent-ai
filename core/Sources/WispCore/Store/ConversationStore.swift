import Foundation

public struct ConversationRecord: Codable, Identifiable, Sendable, Equatable {
    public let id: UUID
    public var sessionId: String?
    public var title: String
    public var updatedAt: Date
    public var telegramThread: Int?
    public var cwd: String?

    public init(
        id: UUID, sessionId: String?, title: String, updatedAt: Date,
        telegramThread: Int? = nil, cwd: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.title = title
        self.updatedAt = updatedAt
        self.telegramThread = telegramThread
        self.cwd = cwd
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

    private var fileURL: URL { directory.appendingPathComponent("conversations.json") }
    private var badURL: URL { directory.appendingPathComponent("conversations.json.bad") }

    public init(directory: URL = ConversationStore.defaultDirectory) {
        self.directory = directory
        load()
    }

    public func all() -> [ConversationRecord] {
        lock.lock()
        defer { lock.unlock() }
        return sorted(records)
    }

    public func upsert(_ record: ConversationRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        var next = records
        if let index = next.firstIndex(where: { $0.id == record.id }) {
            next[index] = record
        } else {
            next.append(record)
        }
        try persist(next)
        records = next
    }

    public func delete(id: UUID) throws {
        lock.lock()
        defer { lock.unlock() }
        let next = records.filter { $0.id != id }
        try persist(next)
        records = next
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
    }

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
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
