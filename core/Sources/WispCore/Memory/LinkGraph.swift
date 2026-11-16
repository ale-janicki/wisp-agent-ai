import Foundation

public struct GraphNode: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let folder: String
    public internal(set) var degree: Int
    public let isGhost: Bool

    public var path: String? { isGhost ? nil : id }
}

public struct GraphEdge: Sendable, Hashable {
    public let a: Int
    public let b: Int

    public init(_ x: Int, _ y: Int) {
        a = min(x, y)
        b = max(x, y)
    }
}

public struct LinkGraph: Sendable, Equatable {
    public internal(set) var nodes: [GraphNode]
    public internal(set) var edges: [GraphEdge]

    public static let empty = LinkGraph(nodes: [], edges: [])

    init(nodes: [GraphNode], edges: [GraphEdge]) {
        self.nodes = nodes
        self.edges = edges
    }

    public static func build(links: [String: [String]], includeGhosts: Bool = false) -> LinkGraph {
        let paths = links.keys.sorted()
        let resolver = LinkResolver(paths: paths)
        var index: [String: Int] = [:]
        var nodes: [GraphNode] = []
        nodes.reserveCapacity(paths.count)
        for (i, path) in paths.enumerated() {
            index[path] = i
            nodes.append(GraphNode(id: path, title: MemoryNote.title(of: path), folder: topFolder(of: path), degree: 0, isGhost: false))
        }
        var seen = Set<GraphEdge>()
        var edges: [GraphEdge] = []
        for (i, path) in paths.enumerated() {
            for target in links[path] ?? [] {
                let j: Int
                if let resolved = resolver.resolve(target, from: path), let found = index[resolved] {
                    j = found
                } else if includeGhosts, let name = LinkResolver.ghostName(target) {
                    let id = "ghost:" + name.lowercased()
                    if let found = index[id] {
                        j = found
                    } else {
                        j = nodes.count
                        index[id] = j
                        nodes.append(GraphNode(id: id, title: name, folder: "", degree: 0, isGhost: true))
                    }
                } else {
                    continue
                }
                guard i != j else { continue }
                let edge = GraphEdge(i, j)
                if seen.insert(edge).inserted { edges.append(edge) }
            }
        }
        for edge in edges {
            nodes[edge.a].degree += 1
            nodes[edge.b].degree += 1
        }
        return LinkGraph(nodes: nodes, edges: edges)
    }

    public static func topFolder(of path: String) -> String {
        guard let slash = path.firstIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    public func adjacency() -> [[Int]] {
        var list = Array(repeating: [Int](), count: nodes.count)
        for edge in edges {
            list[edge.a].append(edge.b)
            list[edge.b].append(edge.a)
        }
        return list
    }

    public func neighborhood(of start: Int, depth: Int, adjacency: [[Int]]) -> Set<Int> {
        guard nodes.indices.contains(start) else { return [] }
        var found: Set<Int> = [start]
        var frontier = [start]
        for _ in 0..<max(0, depth) {
            var next: [Int] = []
            for node in frontier {
                for neighbor in adjacency[node] where found.insert(neighbor).inserted { next.append(neighbor) }
            }
            if next.isEmpty { break }
            frontier = next
        }
        return found
    }

    public func folders() -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for node in nodes where !node.isGhost { counts[node.folder, default: 0] += 1 }
        return counts.map { (name: $0.key, count: $0.value) }.sorted { $0.count > $1.count || ($0.count == $1.count && $0.name < $1.name) }
    }
}

public enum WikiLinks {
    public static func targets(in text: String) -> [String] {
        targets(inUTF8: Data(text.utf8))
    }

    public static func targets(inUTF8 data: Data) -> [String] {
        data.withUnsafeBytes { raw in
            scan(raw.bindMemory(to: UInt8.self))
        }
    }

    private static let newline = UInt8(ascii: "\n"), space = UInt8(ascii: " "), tab = UInt8(ascii: "\t")
    private static let backtick = UInt8(ascii: "`"), tilde = UInt8(ascii: "~")
    private static let open = UInt8(ascii: "["), close = UInt8(ascii: "]")
    private static let pipe = UInt8(ascii: "|"), hash = UInt8(ascii: "#"), backslash = UInt8(ascii: "\\")

    private static func scan(_ bytes: UnsafeBufferPointer<UInt8>) -> [String] {
        var out: [String] = []
        var fence: (mark: UInt8, length: Int)?
        var start = 0
        let count = bytes.count
        while start < count {
            var end = start
            while end < count && bytes[end] != newline { end += 1 }
            var first = start
            while first < end && first - start < 4 && (bytes[first] == space || bytes[first] == tab) { first += 1 }
            var isFenceLine = false
            if first < end, bytes[first] == backtick || bytes[first] == tilde {
                let mark = bytes[first]
                var run = first
                while run < end && bytes[run] == mark { run += 1 }
                if run - first >= 3 {
                    isFenceLine = true
                    if let open = fence {
                        if open.mark == mark && run - first >= open.length { fence = nil }
                    } else {
                        fence = (mark, run - first)
                    }
                }
            }
            if !isFenceLine && fence == nil { scanLine(bytes, from: start, to: end, into: &out) }
            start = end + 1
        }
        return out
    }

    private static func scanLine(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int, into out: inout [String]) {
        var i = start
        while i < end {
            let byte = bytes[i]
            if byte == backtick {
                var run = i
                while run < end && bytes[run] == backtick { run += 1 }
                let length = run - i
                if let closing = closingBackticks(bytes, length: length, from: run, to: end) {
                    i = closing
                } else {
                    i = run
                }
                continue
            }
            if byte == open, i + 1 < end, bytes[i + 1] == open {
                var j = i + 2
                var closed = -1
                while j + 1 < end {
                    if bytes[j] == open && bytes[j + 1] == open { break }
                    if bytes[j] == close && bytes[j + 1] == close {
                        closed = j
                        break
                    }
                    j += 1
                }
                if closed < 0 {
                    i = j + 1 < end ? j : end
                    continue
                }
                if let target = target(bytes, from: i + 2, to: closed) { out.append(target) }
                i = closed + 2
                continue
            }
            i += 1
        }
    }

    private static func closingBackticks(_ bytes: UnsafeBufferPointer<UInt8>, length: Int, from start: Int, to end: Int) -> Int? {
        var i = start
        while i < end {
            guard bytes[i] == backtick else {
                i += 1
                continue
            }
            var run = i
            while run < end && bytes[run] == backtick { run += 1 }
            if run - i == length { return run }
            i = run
        }
        return nil
    }

    private static func target(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> String? {
        var stop = end
        for k in start..<end where bytes[k] == pipe || bytes[k] == hash {
            stop = k
            break
        }
        if stop > start, stop < end, bytes[stop] == pipe, bytes[stop - 1] == backslash { stop -= 1 }
        var lower = start
        while lower < stop && (bytes[lower] == space || bytes[lower] == tab) { lower += 1 }
        var upper = stop
        while upper > lower && (bytes[upper - 1] == space || bytes[upper - 1] == tab) { upper -= 1 }
        guard upper > lower else { return nil }
        return String(decoding: UnsafeBufferPointer(rebasing: bytes[lower..<upper]), as: UTF8.self)
    }
}

public struct LinkResolver: Sendable {
    private var byName: [String: [String]] = [:]
    private var byPath: [String: String] = [:]

    static let attachmentExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "svg", "webp", "avif", "heic", "tif", "tiff", "ico",
        "pdf", "mp3", "wav", "m4a", "ogg", "flac", "3gp", "webm", "mp4", "mov", "mkv", "ogv",
        "canvas", "base", "html", "htm", "csv", "json", "py", "sh", "txt", "zip", "excalidraw",
    ]

    public init(paths: [String]) {
        for path in paths {
            let key = Self.stripMarkdown(path.lowercased())
            byPath[key] = path
            byName[Self.lastComponent(key), default: []].append(path)
        }
        for (name, list) in byName where list.count > 1 {
            byName[name] = list.sorted(by: Self.prefers)
        }
    }

    public func resolve(_ target: String, from source: String) -> String? {
        var key = Self.stripMarkdown(target.trimmingCharacters(in: .whitespaces).lowercased())
        while key.hasPrefix("/") { key.removeFirst() }
        guard !key.isEmpty else { return nil }
        guard key.contains("/") else { return byName[key]?.first }
        if let exact = byPath[key] { return exact }
        let folder = (source.lowercased() as NSString).deletingLastPathComponent
        if let relative = Self.normalize(folder.isEmpty ? key : folder + "/" + key), let hit = byPath[relative] {
            return hit
        }
        let suffix = "/" + key
        return byName[Self.lastComponent(key)]?.first { Self.stripMarkdown($0.lowercased()).hasSuffix(suffix) }
    }

    public static func ghostName(_ target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        let name = lastComponent(trimmed)
        let ext = (name as NSString).pathExtension.lowercased()
        if attachmentExtensions.contains(ext) { return nil }
        let title = stripMarkdown(name)
        return title.isEmpty ? nil : title
    }

    private static func prefers(_ a: String, _ b: String) -> Bool {
        let depthA = a.utf8.count { $0 == UInt8(ascii: "/") }, depthB = b.utf8.count { $0 == UInt8(ascii: "/") }
        if depthA != depthB { return depthA < depthB }
        if a.count != b.count { return a.count < b.count }
        return a < b
    }

    private static func stripMarkdown(_ value: String) -> String {
        value.lowercased().hasSuffix(".md") ? String(value.dropLast(3)) : value
    }

    private static func lastComponent(_ value: String) -> String {
        guard let slash = value.lastIndex(of: "/") else { return value }
        return String(value[value.index(after: slash)...])
    }

    private static func normalize(_ path: String) -> String? {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }
}

public struct LinkScanCache: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var modified: Double
        public var size: Int64
        public var links: [String]
    }

    public static let version = 1

    public var version: Int
    public var root: String
    public var files: [String: Entry]

    public init(root: String, files: [String: Entry] = [:]) {
        self.version = Self.version
        self.root = root
        self.files = files
    }

    public static func load(from url: URL) -> LinkScanCache? {
        guard let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(LinkScanCache.self, from: data),
              cache.version == version
        else { return nil }
        return cache
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

public struct LinkScanStats: Sendable, Equatable {
    public var notes = 0
    public var read = 0
    public var reused = 0
    public var placeholders = 0
    public var unreadable = 0
}

public struct LinkScan: Sendable {
    public var graph: LinkGraph
    public var cache: LinkScanCache
    public var stats: LinkScanStats
}

public enum LinkScanError: Error, Equatable, LocalizedError {
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let path): "a pasta \(path) não está acessível"
        }
    }
}

public enum LinkGraphScanner {
    static let datalessFlag: UInt32 = 0x4000_0000

    public static func scan(
        root: String,
        cache: LinkScanCache? = nil,
        includeGhosts: Bool = false,
        progress: (@Sendable (Int) -> Void)? = nil
    ) throws -> LinkScan {
        let base = canonicalPath(MemorySearch.resolvedRoot(root))
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: base, isDirectory: &isDirectory), isDirectory.boolValue,
              (try? fileManager.contentsOfDirectory(atPath: base)) != nil,
              let enumerator = fileManager.enumerator(
                  at: URL(fileURLWithPath: base, isDirectory: true),
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsPackageDescendants]
              )
        else { throw LinkScanError.unreachable(base) }

        let previous = cache?.root == base ? cache?.files ?? [:] : [:]
        let prefix = base.hasSuffix("/") ? base : base + "/"
        var stats = LinkScanStats()
        var files: [String: LinkScanCache.Entry] = [:]
        var pending: [(relative: String, url: URL, modified: Double, size: Int64)] = []

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            if name.hasPrefix(".") {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    enumerator.skipDescendants()
                } else if name.lowercased().hasSuffix(".md.icloud") {
                    stats.placeholders += 1
                }
                continue
            }
            guard name.lowercased().hasSuffix(".md"), url.path.hasPrefix(prefix) else { continue }
            var info = stat()
            guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            if info.st_flags & datalessFlag != 0 {
                stats.placeholders += 1
                continue
            }
            let relative = String(url.path.dropFirst(prefix.count))
            let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
            let size = Int64(info.st_size)
            if let old = previous[relative], old.modified == modified, old.size == size {
                files[relative] = old
                stats.reused += 1
            } else {
                pending.append((relative, url, modified, size))
            }
        }
        let reused = stats.reused, toRead = pending
        progress?(reused)

        let results = ReadResults(count: toRead.count)
        DispatchQueue.concurrentPerform(iterations: toRead.count) { i in
            let item = toRead[i]
            if let data = try? Data(contentsOf: item.url, options: .mappedIfSafe) {
                results.set(i, LinkScanCache.Entry(modified: item.modified, size: item.size, links: WikiLinks.targets(inUTF8: data)))
            }
            let done = results.tick()
            if done % 100 == 0 { progress?(reused + done) }
        }
        for (i, item) in pending.enumerated() {
            if let entry = results.entries[i] {
                files[item.relative] = entry
                stats.read += 1
            } else {
                stats.unreadable += 1
            }
        }
        stats.notes = files.count
        progress?(stats.notes)
        let graph = LinkGraph.build(links: files.mapValues(\.links), includeGhosts: includeGhosts)
        return LinkScan(graph: graph, cache: LinkScanCache(root: base, files: files), stats: stats)
    }

    private static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

private final class ReadResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var entries: [LinkScanCache.Entry?]
    private var done = 0

    init(count: Int) {
        entries = Array(repeating: nil, count: count)
    }

    func set(_ index: Int, _ entry: LinkScanCache.Entry) {
        lock.lock()
        entries[index] = entry
        lock.unlock()
    }

    func tick() -> Int {
        lock.lock()
        defer { lock.unlock() }
        done += 1
        return done
    }
}
