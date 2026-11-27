import Foundation

public struct TaskItem: Identifiable, Equatable, Sendable {
    public let line: String
    public let occurrence: Int
    public let owner: String?
    public let front: String?
    public let title: String
    public let detail: String
    public let urgent: Bool
    /// The `alerta:<key>` id the alert tool writes in the line's comment, when present.
    public let alertId: String?

    /// Stable across in-place text edits when the line carries a chave; the raw line otherwise.
    public var identity: String { alertId.map { "alerta:\($0)" } ?? line }

    public var id: String { "\(occurrence)|\(line)" }
}

public struct TaskGroup: Identifiable, Equatable, Sendable {
    public let title: String?
    public let items: [TaskItem]

    public var id: String { title ?? "" }
}

public enum TaskListError: Error, Equatable, LocalizedError {
    case lineChanged
    case lockBusy

    public var errorDescription: String? {
        switch self {
        case .lineChanged: "essa linha mudou no arquivo; recarreguei a lista"
        case .lockBusy: "o arquivo está ocupado por outro escritor; nada foi apagado"
        }
    }
}

public enum TaskList {
    public static func parse(_ text: String) -> [TaskGroup] {
        var groups: [TaskGroup] = []
        var title: String?
        var items: [TaskItem] = []
        var seen: [String: Int] = [:]
        var fenced = false
        let all = lines(of: text)

        func isRule(_ line: String) -> Bool { trimmedEnd(line) == "---" }
        var start = 0
        if let first = all.first, isRule(first) {
            start = all.indices.dropFirst().first { isRule(all[$0]) }.map { $0 + 1 } ?? 0
        }

        func close() {
            if !items.isEmpty { groups.append(TaskGroup(title: title, items: items)) }
            items = []
        }

        for (index, raw) in all.enumerated() {
            let occurrence = seen[raw, default: 0]
            seen[raw] = occurrence + 1
            guard index >= start else { continue }
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if isFence(line) {
                fenced.toggle()
            } else if fenced {
                continue
            } else if line.hasPrefix("## ") {
                close()
                title = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("- ") {
                items.append(item(raw, display: line, occurrence: occurrence))
            }
        }
        close()
        return groups
    }

    public static func openCount(_ groups: [TaskGroup]) -> Int {
        groups.reduce(0) { $0 + $1.items.count }
    }

    public static func urgentFirst(_ groups: [TaskGroup]) -> [TaskGroup] {
        groups.map { group in
            TaskGroup(title: group.title, items: group.items.filter(\.urgent) + group.items.filter { !$0.urgent })
        }
    }

    public static func filter(_ groups: [TaskGroup], query: String) -> [TaskGroup] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return groups }
        return groups.compactMap { group in
            let items = group.items.filter { item in
                let shown = [item.owner, item.front, item.title, item.detail].compactMap { $0 }.joined(separator: " ")
                return words.allSatisfy { shown.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
            return items.isEmpty ? nil : TaskGroup(title: group.title, items: items)
        }
    }

    public static func lineIndex(of item: TaskItem, in text: String) -> Int? {
        let parts = lines(of: text)
        let matches = parts.indices.filter { parts[$0] == item.line }
        return matches.indices.contains(item.occurrence) ? matches[item.occurrence] : nil
    }

    public static func deleting(_ item: TaskItem, from text: String) throws -> String {
        var parts = lines(of: text)
        let matches = parts.indices.filter { parts[$0] == item.line }
        guard matches.indices.contains(item.occurrence) else { throw TaskListError.lineChanged }
        let index = matches[item.occurrence]
        parts.remove(at: index)
        var result = parts.joined(separator: "\n")
        if index == parts.count, index > 0 { result += "\n" }
        return result
    }

    /// The lock other writers of the tasks file take: one writer at a time, so a concurrent `add` is never lost.
    /// Order: `profileLock` (`blocks.tasks.lock`, `~` expanded), the `WISP_TASKS_LOCK` variable, then a per-user cache file.
    public static func lockURL(profileLock: String? = nil) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func resolve(_ path: String) -> URL {
            if path == "~" { return home }
            if path.hasPrefix("~/") { return home.appendingPathComponent(String(path.dropFirst(2))) }
            return URL(fileURLWithPath: path)
        }
        if let path = profileLock, !path.isEmpty { return resolve(path) }
        if let path = ProcessInfo.processInfo.environment["WISP_TASKS_LOCK"], !path.isEmpty { return resolve(path) }
        return home.appendingPathComponent(".cache/wisp/tasks.lock")
    }

    public static func complete(_ item: TaskItem, in url: URL, lock: URL = lockURL(), wait: TimeInterval = 10) throws {
        try FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lock.path, O_CREAT | O_WRONLY, 0o644)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(descriptor) }
        let limit = Date().addingTimeInterval(wait)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard Date() < limit else { throw TaskListError.lockBusy }
            usleep(100_000)
        }
        defer { flock(descriptor, LOCK_UN) }
        let text = try String(contentsOf: url, encoding: .utf8)
        let updated = try deleting(item, from: text)
        try Data(updated.utf8).write(to: url, options: .atomic)
    }

    public static func plain(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        while let open = text.range(of: "[["), let close = text.range(of: "]]", range: open.upperBound..<text.endIndex) {
            let inner = text[open.upperBound..<close.lowerBound]
            let shown = inner.split(separator: "|", maxSplits: 1).last.map(String.init) ?? ""
            text.replaceSubrange(open.lowerBound..<close.upperBound, with: shown)
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static let urgentToken = try! NSRegularExpression(pattern: #"(?<!\S)#urgente(?!\S)"#)
    private static let alertComment = try! NSRegularExpression(pattern: #"<!--\s*alerta:(\S+?)(?:\s+tema:.*?)?\s*-->"#)

    private static func range(_ text: String) -> NSRange { NSRange(text.startIndex..., in: text) }

    private static func trimmedEnd(_ line: String) -> String {
        var result = Substring(line)
        while let last = result.last, last.isWhitespace { result.removeLast() }
        return String(result)
    }

    private static func isFence(_ line: String) -> Bool {
        let trimmed = line.drop { $0.isWhitespace }
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private static func withoutComments(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "<!--") {
            if let close = result.range(of: "-->", range: open.upperBound..<result.endIndex) {
                result.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                result.removeSubrange(open.lowerBound..<result.endIndex)
            }
        }
        return result
    }

    private static func isUrgent(tail: String) -> Bool {
        let visible = withoutComments(tail)
        return urgentToken.firstMatch(in: visible, range: range(visible)) != nil
    }

    private static func clean(tail text: String) -> String {
        let visible = withoutComments(text)
        let bare = urgentToken.stringByReplacingMatches(in: visible, range: range(visible), withTemplate: "")
        return bare.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    private static func alertId(in line: String) -> String? {
        guard let match = alertComment.firstMatch(in: line, range: range(line)),
              let chave = Range(match.range(at: 1), in: line) else { return nil }
        return String(line[chave])
    }

    private static func lines(of text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    private static func item(_ raw: String, display line: String, occurrence: Int) -> TaskItem {
        let body = String(line.dropFirst(2))
        let id = alertId(in: line)
        guard body.hasPrefix("**["),
              let ownerEnd = body.range(of: "]"),
              let boldEnd = body.range(of: "**", range: ownerEnd.upperBound..<body.endIndex)
        else {
            return TaskItem(line: raw, occurrence: occurrence, owner: nil, front: nil, title: plain(clean(tail: body)),
                            detail: "", urgent: isUrgent(tail: body), alertId: id)
        }
        let owner = String(body[body.index(body.startIndex, offsetBy: 3)..<ownerEnd.lowerBound])
        let heading = body[ownerEnd.upperBound..<boldEnd.lowerBound].trimmingCharacters(in: .whitespaces)
        let tail = String(body[boldEnd.upperBound...])
        var detail = clean(tail: tail)
        if detail.hasPrefix(".") { detail.removeFirst() }
        let parts = heading.components(separatedBy: " — ")
        let front = parts.count > 1 ? parts[0] : nil
        let title = parts.count > 1 ? parts.dropFirst().joined(separator: " — ") : heading
        return TaskItem(line: raw, occurrence: occurrence, owner: owner, front: front, title: plain(title), detail: plain(detail),
                        urgent: isUrgent(tail: tail), alertId: id)
    }
}
