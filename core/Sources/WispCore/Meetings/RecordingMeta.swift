import Foundation

public enum RecordingStatus: String, Codable, Equatable, Sendable {
    case recording, transcribing, transcribed, noted, failed
    case interrupted = "interrompida"
}

public enum RecordingMode: String, Codable, Equatable, Sendable {
    case call
}

public enum NoteState: String, Codable, Equatable, Sendable {
    case generated
    case raw
}

public struct RecordingMeta: Codable, Equatable, Sendable {
    public struct Devices: Codable, Equatable, Sendable {
        public var mic: String?
        public var system: String?

        public init(mic: String?, system: String?) {
            self.mic = mic
            self.system = system
        }
    }

    public var version = 1
    public var mode: RecordingMode
    public var startedAt: Date
    public var durationSeconds: Double?
    public var devices: Devices
    public var detectedApp: String?
    public var status: RecordingStatus
    public var failure: String?
    public var sources: RecordingSources?
    public var title: String?
    public var noteFile: String?
    public var noteState: NoteState?
    public var brainNote: String?
    public var metrics: MeetingMetrics?
    public var bookmarks: [MeetingBookmark]?
    public var checklist: [ChecklistItem]?
    public var webhookSentAt: Date?

    public init(
        mode: RecordingMode = .call, startedAt: Date, durationSeconds: Double? = nil, devices: Devices,
        detectedApp: String? = nil, status: RecordingStatus = .recording, failure: String? = nil,
        sources: RecordingSources? = nil, title: String? = nil
    ) {
        self.mode = mode
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.devices = devices
        self.detectedApp = detectedApp
        self.status = status
        self.failure = failure
        self.sources = sources
        self.title = title
    }

    private enum CodingKeys: String, CodingKey {
        case version, mode, devices, status, failure, sources, title, metrics, bookmarks, checklist
        case noteFile = "note_file"
        case noteState = "note_state"
        case brainNote = "brain_note"
        case webhookSentAt = "webhook_sent_at"
        case startedAt = "started_at"
        case durationSeconds = "duration_s"
        case detectedApp = "detected_app"
    }
}

public enum RecordingFolder {
    public static let audioFileName = "audio.m4a"
    public static let rawAudioFileName = "audio.caf"
    public static let metaFileName = "meta.json"
    public static let noteFileName = "nota.md"
    static let folderPermissions = 0o700
    static let filePermissions = 0o600

    public static func defaultRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        WispFolder.layout(environment: environment, home: home).reunioes
    }

    public static func root(
        configured: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return defaultRoot(environment: environment, home: home) }
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return home.appendingPathComponent(String(trimmed.dropFirst(2)), isDirectory: true) }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    public static func name(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    public static func create(root: URL, date: Date, timeZone: TimeZone = .current, fileManager: FileManager = .default) throws -> URL {
        if !fileManager.fileExists(atPath: root.path) {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: folderPermissions], ofItemAtPath: root.path)
        }
        let base = name(for: date, timeZone: timeZone)
        var suffix = 1
        while true {
            let folder = root.appendingPathComponent(suffix == 1 ? base : "\(base)-\(suffix)", isDirectory: true)
            do {
                try fileManager.createDirectory(
                    at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: folderPermissions]
                )
                return folder
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                suffix += 1
            }
        }
    }

    public static func restrictFile(at url: URL, fileManager: FileManager = .default) throws {
        try fileManager.setAttributes([.posixPermissions: filePermissions], ofItemAtPath: url.path)
    }

    public static func hasActiveRecording(
        in root: URL, within seconds: TimeInterval = 60, now: Date = Date(), fileManager: FileManager = .default
    ) -> Bool {
        let names = (try? fileManager.contentsOfDirectory(atPath: root.path)) ?? []
        for name in names {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            let touched = [folder, rawAudioURL(in: folder), audioURL(in: folder), metaURL(in: folder)].compactMap {
                (try? fileManager.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
            }.max()
            guard let touched, now.timeIntervalSince(touched) < seconds else { continue }
            if (try? read(in: folder))?.status == .recording { return true }
        }
        return false
    }

    public static func audioURL(in folder: URL) -> URL { folder.appendingPathComponent(audioFileName) }
    public static func rawAudioURL(in folder: URL) -> URL { folder.appendingPathComponent(rawAudioFileName) }
    public static func metaURL(in folder: URL) -> URL { folder.appendingPathComponent(metaFileName) }
    public static func noteURL(in folder: URL) -> URL { folder.appendingPathComponent(noteFileName) }

    public static func write(_ meta: RecordingMeta, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = metaURL(in: folder)
        try encoder.encode(meta).write(to: url, options: .atomic)
        try restrictFile(at: url)
    }

    public static func read(in folder: URL) throws -> RecordingMeta {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingMeta.self, from: Data(contentsOf: metaURL(in: folder)))
    }
}
