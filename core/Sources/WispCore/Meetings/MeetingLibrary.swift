import Foundation

public struct MeetingEntry: Identifiable, Equatable, Sendable {
    public var folder: URL
    public var meta: RecordingMeta
    public var hasTranscript: Bool
    public var hasNote: Bool

    public var id: String { folder.lastPathComponent }
    public var noteURL: URL { RecordingFolder.noteURL(in: folder) }
}

public extension RecordingFolder {
    @discardableResult
    static func update(in folder: URL, _ change: (inout RecordingMeta) -> Void) throws -> RecordingMeta {
        var meta = try read(in: folder)
        change(&meta)
        try write(meta, in: folder)
        return meta
    }
}

public enum MeetingLibrary {
    public static func list(root: URL, fileManager: FileManager = .default) -> [MeetingEntry] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return [] }
        var entries: [MeetingEntry] = []
        for name in names {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            guard let meta = try? RecordingFolder.read(in: folder) else { continue }
            entries.append(MeetingEntry(
                folder: folder, meta: meta,
                hasTranscript: fileManager.fileExists(atPath: MeetingTranscriptFile.url(in: folder).path),
                hasNote: fileManager.fileExists(atPath: RecordingFolder.noteURL(in: folder).path)
            ))
        }
        return entries.sorted { ($0.meta.startedAt, $0.id) > ($1.meta.startedAt, $1.id) }
    }

    public static func needsProcessing(_ entry: MeetingEntry) -> Bool {
        switch entry.meta.status {
        case .transcribing, .interrupted: true
        case .transcribed: entry.hasTranscript && !entry.hasNote && entry.meta.failure == nil && entry.meta.summaryDeferred != true
        case .recording, .noted, .failed: false
        }
    }

    public static func pending(root: URL, excluding active: Set<String> = []) -> [MeetingEntry] {
        list(root: root).filter { needsProcessing($0) && !active.contains($0.id) }
    }
}
