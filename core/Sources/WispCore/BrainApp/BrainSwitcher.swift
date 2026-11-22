import Foundation

public struct BrainSwitcherEntry: Sendable, Equatable {
    public var path: String
    public var title: String
    public var aliases: [String]
    public var modified: Double
    fileprivate var foldedTitle: [UInt8]
    fileprivate var foldedAliases: [[UInt8]]
    fileprivate var foldedPath: [UInt8]

    public init(path: String, title: String, aliases: [String] = [], modified: Double = 0) {
        self.path = path
        self.title = title
        self.aliases = aliases
        self.modified = modified
        foldedTitle = Array(BrainText.fold(title).utf8)
        foldedAliases = aliases.map { Array(BrainText.fold($0).utf8) }
        foldedPath = Array(BrainText.fold(BrainText.withoutMarkdownSuffix(path)).utf8)
    }
}

public struct BrainSwitcherResult: Sendable, Equatable, Identifiable {
    public var path: String
    public var title: String
    public var alias: String?
    public var score: Int

    public var id: String { path }
}

public enum BrainSwitcher {
    public static func entries(from catalog: BrainCatalog) -> [BrainSwitcherEntry] {
        catalog.notes.values.map { BrainSwitcherEntry(path: $0.path, title: $0.title, aliases: $0.aliases, modified: $0.modified) }
    }

    public static func rank(_ query: String, in entries: [BrainSwitcherEntry], limit: Int = 30) -> [BrainSwitcherResult] {
        let needle = Array(BrainText.fold(query.trimmingCharacters(in: .whitespaces)).utf8)
        guard !needle.isEmpty else {
            return entries.sorted { $0.modified > $1.modified || ($0.modified == $1.modified && $0.path < $1.path) }
                .prefix(limit).map { BrainSwitcherResult(path: $0.path, title: $0.title, alias: nil, score: 0) }
        }
        var scored: [BrainSwitcherResult] = []
        scored.reserveCapacity(64)
        for entry in entries {
            var best: (score: Int, alias: String?)?
            if let score = score(needle, in: entry.foldedTitle) { best = (score + 20, nil) }
            for (index, alias) in entry.foldedAliases.enumerated() {
                if let score = score(needle, in: alias), score + 10 > (best?.score ?? 0) { best = (score + 10, entry.aliases[index]) }
            }
            if best == nil, let score = score(needle, in: entry.foldedPath) { best = (score / 2, nil) }
            if let best { scored.append(BrainSwitcherResult(path: entry.path, title: entry.title, alias: best.alias, score: best.score - entry.title.count / 8)) }
        }
        scored.sort { $0.score > $1.score || ($0.score == $1.score && ($0.title.count, $0.path) < ($1.title.count, $1.path)) }
        return Array(scored.prefix(limit))
    }

    static func score(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        if let at = firstRange(of: needle, in: haystack) {
            let boundary = at == 0 || isSeparator(haystack[at - 1])
            let exact = needle.count == haystack.count
            return 200 - min(at, 60) + (boundary ? 40 : 0) + (exact ? 100 : 0)
        }
        var total = 0
        var next = 0
        var previous = -2
        for byte in needle {
            guard let found = (next..<haystack.count).first(where: { haystack[$0] == byte }) else { return nil }
            var gain = 1
            if found == 0 || isSeparator(haystack[found - 1]) { gain += 12 }
            if found == previous + 1 { gain += 8 }
            total += gain - min(found - max(previous, -1) - 1, 3)
            previous = found
            next = found + 1
        }
        return max(total, 1)
    }

    private static func firstRange(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        let last = haystack.count - needle.count
        var i = 0
        while i <= last {
            if haystack[i] == needle[0], haystack[i..<(i + needle.count)].elementsEqual(needle) { return i }
            i += 1
        }
        return nil
    }

    private static func isSeparator(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x2D || byte == 0x5F || byte == 0x2F || byte == 0x2E
    }
}

public struct BrainCompletionContext: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case link, tag }

    public var kind: Kind
    public var query: String
    public var range: NSRange
}

public enum BrainCompletion {
    public static func context(in text: String, cursor: Int) -> BrainCompletionContext? {
        let ns = text as NSString
        guard cursor >= 0, cursor <= ns.length else { return nil }
        let lineStart = ns.lineRange(for: NSRange(location: cursor, length: 0)).location
        let head = ns.substring(with: NSRange(location: lineStart, length: cursor - lineStart)) as NSString
        let open = head.range(of: "[[", options: .backwards)
        if open.location != NSNotFound {
            let typed = head.substring(from: open.location + 2) as NSString
            if typed.range(of: "]]").location == NSNotFound, typed.range(of: "|").location == NSNotFound, typed.range(of: "#").location == NSNotFound,
               typed.range(of: "[").location == NSNotFound {
                return BrainCompletionContext(kind: .link, query: typed as String, range: NSRange(location: lineStart + open.location + 2, length: typed.length))
            }
        }
        var index = head.length
        while index > 0 {
            let character = head.character(at: index - 1)
            guard let scalar = Unicode.Scalar(character) else { return nil }
            let allowed = CharacterSet.alphanumerics.contains(scalar) || character == 0x5F || character == 0x2D || character == 0x2F
            if allowed { index -= 1; continue }
            if character == 0x23, index == 1 || head.character(at: index - 2) == 0x20 || head.character(at: index - 2) == 0x09 {
                let typed = head.substring(from: index)
                return BrainCompletionContext(kind: .tag, query: typed, range: NSRange(location: lineStart + index, length: typed.count))
            }
            return nil
        }
        return nil
    }

    public static func linkText(for result: BrainSwitcherResult, catalog: BrainCatalog) -> String {
        let name = catalog.linkName(for: result.path)
        guard let alias = result.alias else { return name }
        return name + "|" + alias
    }

    public static func tags(_ query: String, in counts: [String: Int], limit: Int = 12) -> [String] {
        let needle = BrainText.fold(query)
        return counts.filter { needle.isEmpty || BrainText.fold($0.key).contains(needle) }
            .sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .prefix(limit).map(\.key)
    }
}
