import Foundation

public struct BrainLinkRef: Sendable, Equatable {
    public var name: String
    public var heading: String

    public init(name: String, heading: String) {
        self.name = name
        self.heading = heading
    }
}

public struct BrainNote: Sendable, Equatable, Identifiable {
    public var path: String
    public var title: String
    public var stem: String
    public var aliases: [String]
    public var tags: [String]
    public var inlineTags: [String]
    public var status: String
    public var links: [BrainLinkRef]
    public var modified: Double
    public var size: Int64
    public var hasHeadingTitle: Bool

    public var id: String { path }

    public func moved(to newPath: String) -> BrainNote {
        BrainNote(
            path: newPath, title: hasHeadingTitle ? title : "", aliases: aliases, tags: tags, inlineTags: inlineTags, status: status,
            links: links, modified: modified, size: size)
    }

    public init(
        path: String, title: String = "", aliases: [String] = [], tags: [String] = [], inlineTags: [String] = [],
        status: String = "", links: [BrainLinkRef] = [], modified: Double = 0, size: Int64 = 0
    ) {
        self.path = path
        self.stem = BrainText.stem(of: path)
        self.hasHeadingTitle = !title.isEmpty
        self.title = title.isEmpty ? stem.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ") : title
        self.aliases = aliases
        self.tags = tags
        self.inlineTags = inlineTags
        self.status = status
        self.links = links
        self.modified = modified
        self.size = size
    }
}

public struct BrainResolvedLink: Sendable, Equatable {
    public var name: String
    public var heading: String
    public var target: String?
}

public struct BrainCatalog: Sendable {
    private struct Table {
        var exact: [String: [String]] = [:]
        var folded: [String: [String]] = [:]

        mutating func put(_ key: String, _ path: String) {
            for (level, form) in [(0, key.lowercased()), (1, BrainText.fold(key))] where !form.isEmpty {
                if level == 0 {
                    if exact[form]?.contains(path) != true { exact[form, default: []].append(path) }
                } else if folded[form]?.contains(path) != true {
                    folded[form, default: []].append(path)
                }
            }
        }

        func find(_ key: String) -> [String] {
            if let hit = exact[key.lowercased()], !hit.isEmpty { return hit }
            return folded[BrainText.fold(key)] ?? []
        }
    }

    public let notes: [String: BrainNote]
    private var stems = Table()
    private var aliases = Table()
    private var titles = Table()
    private var paths = Table()
    private var outgoingByNote: [String: [BrainResolvedLink]] = [:]
    private var incomingByNote: [String: [String]] = [:]

    public init(notes list: [BrainNote]) {
        var byPath: [String: BrainNote] = [:]
        for note in list {
            byPath[note.path] = note
            stems.put(note.stem, note.path)
            titles.put(note.title, note.path)
            for alias in note.aliases { aliases.put(alias, note.path) }
            let parts = BrainText.withoutMarkdownSuffix(note.path).split(separator: "/").map(String.init)
            for i in parts.indices { paths.put(parts[i...].joined(separator: "/"), note.path) }
        }
        notes = byPath
        for note in list {
            let resolved = note.links.map { BrainResolvedLink(name: $0.name, heading: $0.heading, target: resolve($0.name, from: note.path)) }
            outgoingByNote[note.path] = resolved
            for target in Set(resolved.compactMap(\.target)) where target != note.path {
                incomingByNote[target, default: []].append(note.path)
            }
        }
        for key in incomingByNote.keys { incomingByNote[key]?.sort() }
    }

    public var isEmpty: Bool { notes.isEmpty }

    public func resolve(_ name: String, from source: String? = nil) -> String? {
        var key = name.trimmingCharacters(in: .whitespaces)
        if key.hasPrefix("./") { key.removeFirst(2) }
        while key.hasPrefix("/") { key.removeFirst() }
        if key.lowercased().hasSuffix(".md") { key.removeLast(3) }
        if key.isEmpty { return source }
        let tables = key.contains("/") ? [paths] : [stems, aliases, titles]
        for table in tables {
            let found = table.find(key)
            if !found.isEmpty { return Self.closest(found, to: source) }
        }
        if key.contains("/"), let source, let relative = Self.normalize(BrainText.parent(of: source), key) {
            let found = paths.find(relative)
            if !found.isEmpty { return Self.closest(found, to: source) }
        }
        return nil
    }

    static func normalize(_ folder: String, _ key: String) -> String? {
        var parts = folder.split(separator: "/").map(String.init)
        for part in key.split(separator: "/") {
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            } else {
                parts.append(String(part))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    public func resolvePath(_ rel: String) -> String? {
        var key = rel
        if key.lowercased().hasSuffix(".md") { key.removeLast(3) }
        while key.hasPrefix("/") { key.removeFirst() }
        let found = paths.find(key)
        return found.isEmpty ? nil : Self.closest(found, to: nil)
    }

    private static func closest(_ found: [String], to source: String?) -> String {
        let home = source.map { BrainText.parent(of: $0) }
        return found.min { a, b in
            let keyA = (BrainText.parent(of: a) != home ? 1 : 0, a.filter { $0 == "/" }.count, a)
            let keyB = (BrainText.parent(of: b) != home ? 1 : 0, b.filter { $0 == "/" }.count, b)
            return keyA < keyB
        } ?? found[0]
    }

    public func outgoing(of path: String) -> [BrainResolvedLink] { outgoingByNote[path] ?? [] }

    public func incoming(of path: String) -> [String] { incomingByNote[path] ?? [] }

    public func linkName(for path: String) -> String {
        guard let note = notes[path] else { return BrainText.withoutMarkdownSuffix(path) }
        return stems.find(note.stem).count == 1 ? note.stem : BrainText.withoutMarkdownSuffix(path)
    }

    public func tagCounts() -> [String: Int] {
        var counts: [String: Int] = [:]
        for note in notes.values {
            for tag in Set(note.tags + note.inlineTags) { counts[tag, default: 0] += 1 }
        }
        return counts
    }
}
