import Foundation

public struct EventLink: Codable, Equatable, Sendable {
    public var key: String
    public var title: String
    public var eventStart: Date
    public var calendar: String?
    public var recordingFolder: String?
    public var notePath: String?
    public var createdAt: Date

    public init(key: String, title: String, eventStart: Date, calendar: String? = nil, recordingFolder: String? = nil,
                notePath: String? = nil, createdAt: Date = Date()) {
        self.key = key
        self.title = title
        self.eventStart = eventStart
        self.calendar = calendar
        self.recordingFolder = recordingFolder
        self.notePath = notePath
        self.createdAt = createdAt
    }
}

public struct EventLinkStore: Sendable {
    public static let sidecarName = "event.json"

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/state/wisp/agenda-links.json")
    }

    public static func key(for event: CalEvent) -> String { event.uid }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func all() -> [String: EventLink] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? Self.decoder().decode([String: EventLink].self, from: data)) ?? [:]
    }

    public func link(for key: String) -> EventLink? { all()[key] }

    public func upsert(_ link: EventLink) throws {
        var current = all()
        if var existing = current[link.key] {
            existing.title = link.title
            existing.eventStart = link.eventStart
            existing.calendar = link.calendar ?? existing.calendar
            existing.recordingFolder = link.recordingFolder ?? existing.recordingFolder
            existing.notePath = link.notePath ?? existing.notePath
            current[link.key] = existing
        } else {
            current[link.key] = link
        }
        try write(current)
    }

    private func write(_ links: [String: EventLink]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(links).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public static func writeSidecar(_ link: EventLink, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let target = folder.appendingPathComponent(sidecarName)
        try encoder.encode(link).write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    public static func readSidecar(in folder: URL) -> EventLink? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(sidecarName)) else { return nil }
        return try? decoder().decode(EventLink.self, from: data)
    }

    public func recordRecording(event: CalEvent, calendarTitle: String?, folder: URL, now: Date = Date()) throws -> EventLink {
        let link = EventLink(key: Self.key(for: event), title: event.title, eventStart: event.start, calendar: calendarTitle,
                             recordingFolder: folder.lastPathComponent, createdAt: now)
        try Self.writeSidecar(link, in: folder)
        try upsert(link)
        return link
    }
}

public enum BrainLinks {
    public static func wikilinks(in notes: String?) -> [String] {
        guard let notes, notes.contains("[[") else { return [] }
        let pattern = try! NSRegularExpression(pattern: #"\[\[([^\]\n]+?)\]\]"#)
        var seen = Set<String>()
        return pattern.matches(in: notes, range: NSRange(notes.startIndex..., in: notes)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: notes) else { return nil }
            var name = String(notes[range])
            if let bar = name.firstIndex(of: "|") { name = String(name[..<bar]) }
            if let hash = name.firstIndex(of: "#") { name = String(name[..<hash]) }
            name = name.trimmingCharacters(in: .whitespaces)
            return name.isEmpty || !seen.insert(name).inserted ? nil : name
        }
    }
}

public struct CreatedNote: Equatable, Sendable {
    public let url: URL
    public let name: String
    public let relativePath: String
    public let created: Bool
}

public enum MeetingNote {
    public static let folder = "meetings"

    public static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
        var out = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out.isEmpty ? "reuniao" : String(out.prefix(60))
    }

    public static func fileName(for event: CalEvent, zone: TimeZone) -> String {
        let parts = TimeZoneKit.wallClock(event.start, in: zone)
        return String(format: "%04d-%02d-%02d-%02dh%02dm-%@", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, slug(event.title))
    }

    public static func markdown(for event: CalEvent, calendarTitle: String?, zone: TimeZone, recordingFolder: String?, now: Date) -> String {
        let parts = TimeZoneKit.wallClock(event.start, in: zone)
        let stamp = String(format: "%04d-%02d-%02d %02d:%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
        let made = TimeZoneKit.wallClock(now, in: zone)
        let createdStamp = String(format: "%04d-%02d-%02d %02d:%02d", made.year ?? 0, made.month ?? 0, made.day ?? 0, made.hour ?? 0, made.minute ?? 0)
        let names = event.attendees.filter { !$0.isMe }.map(\.name)
        let attendees = names.isEmpty ? "[]" : "[" + names.joined(separator: ", ") + "]"
        var lines = [
            "---", "date: \(stamp)", "tags:", "  - meeting", "context: \(event.title)", "attendees: \(attendees)", "status: active",
            "created: \(createdStamp)", "aliases: [\(stamp) — \(event.title)]", "---", "", "# Meeting — \(stamp) — \(event.title)", "",
            "## TL;DR", "", "", "## Context",
        ]
        if let calendarTitle { lines.append("- Calendar: \(calendarTitle)") }
        if let location = event.location { lines.append("- Location: \(location)") }
        if let link = MeetingLinks.detect(event) { lines.append("- Link: \(link.url.absoluteString)") }
        if let recordingFolder { lines.append("- Recording: \(recordingFolder)") }
        lines += ["", "## Attendees"]
        lines += names.isEmpty ? ["- "] : names.map { "- \($0)" }
        lines += ["", "## Notes", "", ""]
        return lines.joined(separator: "\n")
    }

    public static func create(
        for event: CalEvent, calendarTitle: String?, brainRoot: String, zone: TimeZone, recordingFolder: String? = nil,
        now: Date = Date(), fileManager: FileManager = .default
    ) throws -> CreatedNote {
        let root = URL(fileURLWithPath: MemorySearch.resolvedRoot(brainRoot), isDirectory: true)
        let directory = root.appendingPathComponent(folder, isDirectory: true)
        let name = fileName(for: event, zone: zone)
        let target = directory.appendingPathComponent(name + ".md")
        let relative = "\(folder)/\(name).md"
        if fileManager.fileExists(atPath: target.path) {
            return CreatedNote(url: target, name: name, relativePath: relative, created: false)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let body = markdown(for: event, calendarTitle: calendarTitle, zone: zone, recordingFolder: recordingFolder, now: now)
        try body.write(to: target, atomically: true, encoding: .utf8)
        return CreatedNote(url: target, name: name, relativePath: relative, created: true)
    }

    public static func appendingLink(to notes: String?, name: String) -> String {
        let link = "[[\(name)]]"
        guard let notes, !notes.isEmpty else { return link }
        return notes.contains(link) ? notes : notes + "\n\n" + link
    }
}
