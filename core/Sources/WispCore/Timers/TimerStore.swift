import Foundation

public final class TimerStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    public private(set) var lastRecoveryNote: String?

    private var fileURL: URL { directory.appendingPathComponent("timers.json") }
    private var badURL: URL { directory.appendingPathComponent("timers.json.bad") }

    public init(directory: URL = ConversationStore.defaultDirectory) {
        self.directory = directory
    }

    public func load() -> TimerList {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return TimerList() }
        do {
            return try JSONDecoder().decode(TimerList.self, from: Data(contentsOf: fileURL))
        } catch {
            try? fm.removeItem(at: badURL)
            try? fm.moveItem(at: fileURL, to: badURL)
            lastRecoveryNote = "os timers estavam corrompidos; guardei uma cópia em \(badURL.path)"
            return TimerList()
        }
    }

    public func save(_ list: TimerList) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: fileURL, options: .atomic)
    }
}
