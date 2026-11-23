import Foundation

/// Removes recording folders whose meeting is already safe in the brain. Decisions are pure; the Trash call is injected.
public enum MeetingJanitor {
    public static let defaultDays = 7
    public static let dayChoices = [7, 14, 30]

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
        guard entry.meta.brainError == nil, entry.meta.noteState != .raw else { return false }
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
        case removed, skipped, failed
    }

    /// Cleans one eligible entry: decides the note rewrite, asks `isExcluded` live, writes the note, then trashes the
    /// folder. Never hard-deletes. A transcript link that points elsewhere means the note is not ours to judge: skipped.
    public static func clean(
        _ entry: MeetingEntry, now: Date, days: Int, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isExcluded: @Sendable (String) async -> Bool = { _ in false }, trash: (URL) throws -> Void
    ) async -> Outcome {
        guard let notePath = entry.meta.brainNote else { return .skipped }
        let noteURL = URL(fileURLWithPath: notePath)
        guard let text = try? String(contentsOf: noteURL, encoding: .utf8) else { return .skipped }
        let scan = scanTranscriptLinks(in: text, folder: entry.folder, now: now, days: days, home: home)
        if scan.text == nil, scan.foreign > 0 { return .skipped }
        if await isExcluded(entry.id) { return .skipped }
        if let rewritten = scan.text {
            do { try rewritten.write(to: noteURL, atomically: true, encoding: .utf8) } catch { return .skipped }
        }
        do {
            try trash(entry.folder)
            return .removed
        } catch {
            return .failed
        }
    }

    /// Scans every root and cleans what is eligible. Returns how many folders were removed and how many failed.
    public static func run(
        roots: [URL], now: Date = Date(), days: Int, excluded: Set<String> = [],
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        brainNoteExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isExcluded: @Sendable (String) async -> Bool = { _ in false },
        trash: (URL) throws -> Void
    ) async -> (removed: Int, failed: Int) {
        var removed = 0
        var failed = 0
        for root in roots {
            for entry in eligible(MeetingLibrary.list(root: root), now: now, days: days, excluded: excluded, brainNoteExists: brainNoteExists) {
                switch await clean(entry, now: now, days: days, home: home, isExcluded: isExcluded, trash: trash) {
                case .removed: removed += 1
                case .failed: failed += 1
                case .skipped: break
                }
            }
        }
        return (removed, failed)
    }
}
