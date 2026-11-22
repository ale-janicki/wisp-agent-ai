import Foundation

public struct MemoryBlock: Codable, Sendable, Equatable {
    public var root: String?
    public var search: String?

    public init(root: String? = nil, search: String? = nil) {
        self.root = root
        self.search = search
    }
}

public struct MemoryHit: Identifiable, Equatable, Sendable {
    public let path: String
    public var line: Int
    public var text: String

    public var id: String { path }
    public var title: String { MemoryNote.title(of: path) }

    public init(path: String, line: Int, text: String) {
        self.path = path
        self.line = line
        self.text = text
    }
}

public struct MemoryNote: Identifiable, Equatable, Sendable {
    public let path: String
    public var modifiedAt: Date

    public var id: String { path }
    public var title: String { Self.title(of: path) }

    public init(path: String, modifiedAt: Date) {
        self.path = path
        self.modifiedAt = modifiedAt
    }

    public static func title(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    public static func folder(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }
}

public enum MemorySearch {
    static let maxLineLength = 240
    public static let resultLimit = 50

    public static func resolvedRoot(_ root: String) -> String {
        let resolved = URL(fileURLWithPath: expandTilde(root)).resolvingSymlinksInPath().path
        return resolved.count > 1 && resolved.hasSuffix("/") ? String(resolved.dropLast()) : resolved
    }

    public static func relativePath(ofFile file: String, inRoot root: String) -> String? {
        let base = resolvedRoot(root)
        let path = resolvedRoot(file)
        guard path.hasPrefix(base + "/"), path.count > base.count + 1 else { return nil }
        return String(path.dropFirst(base.count + 1))
    }

    public static func command(template: String, query: String, root: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return template
            .replacingOccurrences(of: "{root}", with: shellQuote(root))
            .replacingOccurrences(of: "{query}", with: shellQuote(trimmed))
    }

    public static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func parse(_ data: Data, root: String, limit: Int = resultLimit) -> [MemoryHit] {
        let text = String(decoding: data, as: UTF8.self)
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var seen = Set<String>()
        var hits: [MemoryHit] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            guard let (path, line, body) = split(Substring(raw)) else { continue }
            let relative: String
            if path.hasPrefix(prefix) {
                relative = String(path.dropFirst(prefix.count))
            } else if path.hasPrefix("./") {
                relative = String(path.dropFirst(2))
            } else if !path.hasPrefix("/") {
                relative = path
            } else {
                continue
            }
            guard !relative.isEmpty, seen.insert(relative).inserted else { continue }
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            hits.append(MemoryHit(path: relative, line: line, text: String(trimmed.prefix(maxLineLength))))
            if hits.count == limit { break }
        }
        return hits
    }

    private static func split(_ raw: Substring) -> (String, Int, String)? {
        if let nul = raw.firstIndex(of: "\0") {
            let rest = raw[raw.index(after: nul)...]
            guard let colon = rest.firstIndex(of: ":"), let line = Int(rest[..<colon]) else { return nil }
            return (String(raw[..<nul]), line, String(rest[rest.index(after: colon)...]))
        }
        var index = raw.startIndex
        while let colon = raw[index...].firstIndex(of: ":") {
            let afterColon = raw.index(after: colon)
            let digits = raw[afterColon...].prefix(while: \.isNumber)
            if !digits.isEmpty, digits.endIndex < raw.endIndex, raw[digits.endIndex] == ":", let line = Int(digits) {
                return (String(raw[..<colon]), line, String(raw[raw.index(after: digits.endIndex)...]))
            }
            index = afterColon
        }
        return nil
    }

    public static func ranked(_ hits: [MemoryHit], query: String) -> [MemoryHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return hits }
        let byTitle = hits.filter { $0.title.lowercased().contains(needle) }
        return byTitle + hits.filter { !$0.title.lowercased().contains(needle) }
    }

    public static func obsidianURL(root: String, path: String) -> URL? {
        let vault = (expandTilde(root) as NSString).lastPathComponent
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let name = vault.addingPercentEncoding(withAllowedCharacters: allowed),
              let file = path.addingPercentEncoding(withAllowedCharacters: allowed)
        else { return nil }
        return URL(string: "obsidian://open?vault=\(name)&file=\(file)")
    }

    public static func recentNotes(root: String, limit: Int = 10, fileManager: FileManager = .default) -> [MemoryNote] {
        let base = URL(fileURLWithPath: resolvedRoot(root), isDirectory: true)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(
            at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        var notes: [MemoryNote] = []
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let full = url.path.hasPrefix(prefix) ? url.path : url.resolvingSymlinksInPath().path
            let relative = full.hasPrefix(prefix) ? String(full.dropFirst(prefix.count)) : url.lastPathComponent
            notes.append(MemoryNote(path: relative, modifiedAt: values.contentModificationDate ?? .distantPast))
        }
        return Array(notes.sorted { $0.modifiedAt > $1.modifiedAt || ($0.modifiedAt == $1.modifiedAt && $0.path < $1.path) }.prefix(limit))
    }
}
