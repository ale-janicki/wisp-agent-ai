import Foundation

public final class SettingsStore: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var current: WispSettings = .default
    public private(set) var lastRecoveryNote: String?

    private var fileURL: URL { directory.appendingPathComponent("settings.json") }
    private var badURL: URL { directory.appendingPathComponent("settings.json.bad") }

    public init(directory: URL = ConversationStore.defaultDirectory) {
        self.directory = directory
        load()
    }

    public var settings: WispSettings {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    public func save(_ settings: WispSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
        current = settings
    }

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else { return }
        do {
            current = try JSONDecoder().decode(WispSettings.self, from: Data(contentsOf: fileURL))
            if current.graphWasInvalid {
                current.graphWasInvalid = false
                lastRecoveryNote = "Os ajustes do grafo estavam inválidos e voltaram ao padrão."
            }
        } catch {
            try? fm.removeItem(at: badURL)
            try? fm.moveItem(at: fileURL, to: badURL)
            current = .default
            lastRecoveryNote = "os ajustes estavam corrompidos; guardei uma cópia em \(badURL.path)"
        }
    }
}
