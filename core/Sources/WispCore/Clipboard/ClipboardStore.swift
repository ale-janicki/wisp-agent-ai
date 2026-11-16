import Foundation

public final class ClipboardStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    public private(set) var lastRecoveryNote: String?

    private var fileURL: URL { directory.appendingPathComponent("history.json") }
    private var badURL: URL { directory.appendingPathComponent("history.json.bad") }

    public init(directory: URL = ConversationStore.defaultDirectory.appendingPathComponent("clipboard", isDirectory: true)) {
        self.directory = directory
    }

    public func load() -> ClipboardHistory {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return ClipboardHistory() }
        do {
            return try JSONDecoder().decode(ClipboardHistory.self, from: Data(contentsOf: fileURL))
        } catch {
            try? fm.removeItem(at: badURL)
            try? fm.moveItem(at: fileURL, to: badURL)
            lastRecoveryNote = "o histórico de copiados estava corrompido; guardei uma cópia em \(badURL.path)"
            return ClipboardHistory()
        }
    }

    public func save(_ history: ClipboardHistory) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(history).write(to: fileURL, options: .atomic)
    }

    public func writeImage(png: Data, thumbnail: Data, id: UUID) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = "\(id.uuidString).png"
        try png.write(to: directory.appendingPathComponent(name), options: .atomic)
        try thumbnail.write(to: directory.appendingPathComponent(ClipItem.thumbnailName(for: name)), options: .atomic)
        return name
    }

    public func deleteFiles(of items: [ClipItem]) {
        lock.lock()
        defer { lock.unlock() }
        for name in items.flatMap(\.imageFiles) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    public func url(of name: String) -> URL {
        directory.appendingPathComponent(name)
    }
}
