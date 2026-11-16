import Foundation

public struct TaskItem: Identifiable, Equatable, Sendable {
    public let line: String
    public let occurrence: Int
    public let owner: String?
    public let front: String?
    public let title: String
    public let detail: String

    public var id: String { "\(occurrence)|\(line)" }
}

public struct TaskGroup: Identifiable, Equatable, Sendable {
    public let title: String?
    public let items: [TaskItem]

    public var id: String { title ?? "" }
}

public enum TaskListError: Error, Equatable, LocalizedError {
    case lineChanged

    public var errorDescription: String? {
        switch self {
        case .lineChanged: "essa linha mudou no arquivo; recarreguei a lista"
        }
    }
}

public enum TaskList {
    public static func parse(_ text: String) -> [TaskGroup] {
        var groups: [TaskGroup] = []
        var title: String?
        var items: [TaskItem] = []
        var seen: [String: Int] = [:]
        var inFrontmatter = false

        func close() {
            if !items.isEmpty { groups.append(TaskGroup(title: title, items: items)) }
            items = []
        }

        for (index, raw) in lines(of: text).enumerated() {
            let occurrence = seen[raw, default: 0]
            seen[raw] = occurrence + 1
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if index == 0, line == "---" { inFrontmatter = true; continue }
            if inFrontmatter {
                if line == "---" { inFrontmatter = false }
                continue
            }
            if line.hasPrefix("## ") {
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

    public static func filter(_ groups: [TaskGroup], query: String) -> [TaskGroup] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return groups }
        return groups.compactMap { group in
            let items = group.items.filter { item in
                words.allSatisfy { item.line.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
            }
            return items.isEmpty ? nil : TaskGroup(title: group.title, items: items)
        }
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

    public static func complete(_ item: TaskItem, in url: URL) throws {
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

    private static func lines(of text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    private static func item(_ raw: String, display line: String, occurrence: Int) -> TaskItem {
        let body = String(line.dropFirst(2))
        guard body.hasPrefix("**["),
              let ownerEnd = body.range(of: "]"),
              let boldEnd = body.range(of: "**", range: ownerEnd.upperBound..<body.endIndex)
        else {
            return TaskItem(line: raw, occurrence: occurrence, owner: nil, front: nil, title: plain(body), detail: "")
        }
        let owner = String(body[body.index(body.startIndex, offsetBy: 3)..<ownerEnd.lowerBound])
        let heading = body[ownerEnd.upperBound..<boldEnd.lowerBound].trimmingCharacters(in: .whitespaces)
        var detail = String(body[boldEnd.upperBound...])
        if detail.hasPrefix(".") { detail.removeFirst() }
        let parts = heading.components(separatedBy: " — ")
        let front = parts.count > 1 ? parts[0] : nil
        let title = parts.count > 1 ? parts.dropFirst().joined(separator: " — ") : heading
        return TaskItem(line: raw, occurrence: occurrence, owner: owner, front: front, title: plain(title), detail: plain(detail))
    }
}
