import Foundation

/// Removes recording folders whose meeting is already safe in the brain. Decisions are pure; the Trash call is injected.
public enum MeetingJanitor {
    /// What turning the cleanup on in Settings starts with.
    public static let defaultDays = 7
    public static let maxDays = 365
    public static let dayChoices = [7, 14, 30]

    /// Stored values are 0 (off) or 1...365.
    public static func clamp(days: Int) -> Int { min(max(days, 0), maxDays) }

    /// The recording start: `started_at` from the meta, else the `yyyy-MM-dd_HH-mm-ss` prefix of the folder name.
    public static func recordingDate(startedAt: Date?, folderName: String, timeZone: TimeZone = .current) -> Date? {
        if let startedAt { return startedAt }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.date(from: String(folderName.prefix(19)))
    }

    public static func isEligible(
        _ entry: MeetingEntry, now: Date, days: Int, excluded: Set<String>, brainNoteExists: (String) -> Bool
    ) -> Bool {
        guard days > 0, entry.meta.status == .noted, !excluded.contains(entry.id) else { return false }
        guard entry.meta.brainError == nil, entry.meta.noteState == .generated else { return false }
        guard let brainNote = entry.meta.brainNote, brainNoteExists(brainNote) else { return false }
        guard !contains(folder: entry.folder, path: brainNote) else { return false }
        guard let started = recordingDate(startedAt: entry.meta.startedAt, folderName: entry.id) else { return false }
        return now.timeIntervalSince(started) >= Double(days) * 86_400
    }

    /// True when `path` is the folder itself or anything inside it, with symlinks resolved on both sides.
    static func contains(folder: URL, path: String) -> Bool {
        let root = resolved(folder.path)
        let target = resolved(path)
        return target == root || target.hasPrefix(root + "/")
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func eligible(
        _ entries: [MeetingEntry], now: Date, days: Int, excluded: Set<String> = [],
        brainNoteExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [MeetingEntry] {
        entries.filter { isEligible($0, now: now, days: days, excluded: excluded, brainNoteExists: brainNoteExists) }
    }

    public static func stamp(now: Date, days: Int, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "dd/MM/yyyy"
        return "Transcrição apagada em \(formatter.string(from: now)) (limpeza automática após \(days) dias)."
    }

    /// What the note's `[Transcrição completa](path)` lines say about `folder`: `text` is the note with this folder's
    /// link replaced (nil when none matched) and `foreign` counts links that did not match.
    public struct LinkScan: Equatable, Sendable {
        public var text: String?
        public var foreign: Int
    }

    public static func scanTranscriptLinks(
        in note: String, folder: URL, now: Date, days: Int, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        timeZone: TimeZone = .current
    ) -> LinkScan {
        let prefix = "[Transcrição completa]("
        var lines = note.components(separatedBy: "\n")
        var changed = false
        var foreign = 0
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix), trimmed.hasSuffix(")") else { continue }
            let raw = String(trimmed.dropFirst(prefix.count).dropLast())
            var path = raw.removingPercentEncoding ?? raw
            if path.hasPrefix("~/") { path = home.appendingPathComponent(String(path.dropFirst(2))).path }
            let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            guard resolved(parent.path) == resolved(folder.path) else {
                foreign += 1
                continue
            }
            lines[index] = stamp(now: now, days: days, timeZone: timeZone)
            changed = true
        }
        return LinkScan(text: changed ? lines.joined(separator: "\n") : nil, foreign: foreign)
    }

    /// Replaces the `[Transcrição completa](path)` line whose path lies inside `folder`. Nil when there is no such line.
    public static func rewriteTranscriptLink(
        in note: String, folder: URL, now: Date, days: Int, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        timeZone: TimeZone = .current
    ) -> String? {
        scanTranscriptLinks(in: note, folder: folder, now: now, days: days, home: home, timeZone: timeZone).text
    }

    public enum Outcome: Equatable, Sendable {
        case removed, skipped
        case failed(String)
    }

    public struct Report: Sendable {
        public var removedNames: [String] = []
        public var failures: [String] = []
        public var removed: Int { removedNames.count }
        public var failed: Int { failures.count }
    }

    /// Cleans one eligible entry. Order: re-read the meta, read the note (content and mtime), decide the rewrite, ask
    /// `isExcluded` live, re-check the note is unchanged, write it atomically keeping permissions and xattrs, confirm it
    /// on disk, then trash. Never hard-deletes. A transcript link that points elsewhere means the note is not ours to
    /// judge: skipped. When the trash fails after the rewrite there is no link left, so the next sweep only trashes.
    public static func clean(
        _ entry: MeetingEntry, now: Date, days: Int, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        brainNoteExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isExcluded: @Sendable (String) async -> Bool = { _ in false },
        beforeWrite: () -> Void = {}, trash: (URL) throws -> Void
    ) async -> Outcome {
        guard let meta = try? RecordingFolder.read(in: entry.folder), meta.status == .noted, meta.noteState == .generated,
            meta.brainError == nil, let notePath = meta.brainNote, brainNoteExists(notePath),
            !contains(folder: entry.folder, path: notePath)
        else { return .skipped }
        let noteURL = URL(fileURLWithPath: notePath)
        guard let before = NoteSnapshot(noteURL) else { return .skipped }
        let scan = scanTranscriptLinks(in: before.text, folder: entry.folder, now: now, days: days, home: home)
        if scan.text == nil, scan.foreign > 0 { return .skipped }
        if await isExcluded(entry.id) { return .skipped }
        if let rewritten = scan.text {
            beforeWrite()
            guard NoteSnapshot(noteURL) == before else { return .skipped }
            guard replace(noteURL, with: rewritten), NoteSnapshot(noteURL)?.text == rewritten else { return .skipped }
        }
        do {
            try trash(entry.folder)
            return .removed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Scans every root and cleans what is eligible.
    public static func run(
        roots: [URL], now: Date = Date(), days: Int, excluded: Set<String> = [],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        brainNoteExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isExcluded: @Sendable (String) async -> Bool = { _ in false },
        beforeWrite: () -> Void = {},
        trash: (URL) throws -> Void
    ) async -> Report {
        var report = Report()
        for root in roots {
            for entry in eligible(MeetingLibrary.list(root: root), now: now, days: days, excluded: excluded, brainNoteExists: brainNoteExists) {
                let outcome = await clean(
                    entry, now: now, days: days, home: home, brainNoteExists: brainNoteExists,
                    isExcluded: isExcluded, beforeWrite: beforeWrite, trash: trash)
                switch outcome {
                case .removed: report.removedNames.append(entry.id)
                case .failed(let reason): report.failures.append("\(entry.id): \(reason)")
                case .skipped: break
                }
            }
        }
        return report
    }

    private struct NoteSnapshot: Equatable {
        var text: String
        var modified: Date

        init?(_ url: URL) {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            else { return nil }
            self.text = text
            self.modified = modified
        }
    }

    /// Atomic replace through a sibling temp file that carries the original permissions and extended attributes.
    private static func replace(_ url: URL, with text: String) -> Bool {
        let fileManager = FileManager.default
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        do {
            try text.write(to: temp, atomically: false, encoding: .utf8)
            if let permissions = (try fileManager.attributesOfItem(atPath: url.path))[.posixPermissions] {
                try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: temp.path)
            }
            copyExtendedAttributes(from: url, to: temp)
            _ = try fileManager.replaceItemAt(url, withItemAt: temp)
            return true
        } catch {
            try? fileManager.removeItem(at: temp)
            return false
        }
    }

    private static func copyExtendedAttributes(from source: URL, to target: URL) {
        #if canImport(Darwin)
        let size = listxattr(source.path, nil, 0, 0)
        guard size > 0 else { return }
        var names = [CChar](repeating: 0, count: size)
        guard listxattr(source.path, &names, size, 0) == size else { return }
        var start = 0
        while start < size {
            let name = String(cString: Array(names[start...]))
            start += name.utf8.count + 1
            let length = getxattr(source.path, name, nil, 0, 0, 0)
            guard length >= 0 else { continue }
            var value = [UInt8](repeating: 0, count: length)
            if getxattr(source.path, name, &value, length, 0, 0) == length {
                _ = setxattr(target.path, name, value, length, 0, 0)
            }
        }
        #endif
    }
}
