import Foundation

public struct BrainHistory: Sendable, Equatable {
    public private(set) var entries: [String] = []
    public private(set) var position = -1

    public init() {}

    public var current: String? { entries.indices.contains(position) ? entries[position] : nil }
    public var canGoBack: Bool { position > 0 }
    public var canGoForward: Bool { position + 1 < entries.count }

    public mutating func visit(_ path: String) {
        guard current != path else { return }
        entries = Array(entries.prefix(position + 1)) + [path]
        position = entries.count - 1
    }

    public mutating func back() -> String? {
        guard canGoBack else { return nil }
        position -= 1
        return current
    }

    public mutating func forward() -> String? {
        guard canGoForward else { return nil }
        position += 1
        return current
    }

    public mutating func rename(_ from: String, to: String) {
        entries = entries.map { $0 == from ? to : ($0.hasPrefix(from + "/") ? to + $0.dropFirst(from.count) : $0) }
    }

    public mutating func forget(_ path: String) {
        var kept: [String] = []
        var newPosition = -1
        for (index, entry) in entries.enumerated() where entry != path && !entry.hasPrefix(path + "/") {
            if kept.last == entry { if index <= position { newPosition = kept.count - 1 }; continue }
            kept.append(entry)
            if index <= position { newPosition = kept.count - 1 }
        }
        entries = kept
        position = min(max(newPosition, kept.isEmpty ? -1 : 0), kept.count - 1)
    }
}

public struct BrainBookmarks: Sendable, Equatable {
    public private(set) var paths: [String]

    public init(paths: [String] = []) { self.paths = paths }

    public func contains(_ path: String) -> Bool { paths.contains(path) }

    public mutating func toggle(_ path: String) {
        if let index = paths.firstIndex(of: path) { paths.remove(at: index) } else { paths.append(path) }
    }

    public mutating func rename(_ from: String, to: String) {
        paths = paths.map { $0 == from ? to : ($0.hasPrefix(from + "/") ? to + $0.dropFirst(from.count) : $0) }
    }

    public mutating func forget(_ path: String) {
        paths.removeAll { $0 == path || $0.hasPrefix(path + "/") }
    }

    public static func load(from url: URL, root: String) -> BrainBookmarks {
        guard let data = try? Data(contentsOf: url),
              let all = (try? JSONDecoder().decode([String: [String]].self, from: data)) else { return BrainBookmarks() }
        return BrainBookmarks(paths: all[MemorySearch.resolvedRoot(root)] ?? [])
    }

    public func save(to url: URL, root: String) throws {
        var all = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: [String]].self, from: $0) } ?? [:]
        all[MemorySearch.resolvedRoot(root)] = paths
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(all).write(to: url, options: .atomic)
    }
}

public struct BrainSearchHit: Sendable, Equatable, Identifiable {
    public var path: String
    public var title: String
    public var snippet: String
    public var score: Double

    public var id: String { path }
}

public enum BrainSearchClient {
    public static func arguments(root: String, query: String, limit: Int) -> [String] {
        ["brain", "search", query, "--root", root, "--limit", String(limit)]
    }

    public static func decode(_ data: Data) -> [BrainSearchHit]? {
        struct Row: Decodable {
            var path: String
            var title: String
            var snippet: String
            var score: Double
        }
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { return nil }
        return rows.map { BrainSearchHit(path: $0.path, title: $0.title, snippet: $0.snippet, score: $0.score) }
    }

    public static func run(wisp: URL, environment: [String: String], root: String, query: String, limit: Int = 30, timeout: TimeInterval = 20) -> Result<[BrainSearchHit], BrainFilesError> {
        switch CommandRunner.run(executable: wisp, arguments: arguments(root: root, query: query, limit: limit), environment: environment, timeout: timeout) {
        case .failure(let error):
            return .failure(.failed(error.localizedDescription))
        case .success(let output):
            guard !output.timedOut, output.status == 0, let hits = decode(output.stdout) else {
                let message = String(decoding: output.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                return .failure(.failed(message.isEmpty ? "a busca no brain não respondeu" : message))
            }
            return .success(hits)
        }
    }
}

public enum BrainRecovery {
    private static let counter = NSLock()
    nonisolated(unsafe) private static var sequence = 0

    private static func next() -> Int {
        counter.withLock {
            sequence += 1
            return sequence
        }
    }

    static func fileName(for path: String, now: Date, sequence: Int) -> String {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmssSSS"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        var name = path.replacingOccurrences(of: "/", with: "__")
        if name.count > 48 {
            var hash: UInt64 = 1469598103934665603
            for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
            name = String(format: "%016llx", hash) + "-" + String((path as NSString).lastPathComponent.suffix(24))
        }
        return "\(stamp.string(from: now))-\(sequence)-\(name)"
    }

    public static func save(_ text: String, named path: String, in folder: URL, now: Date = Date()) -> URL? {
        let url = folder.appendingPathComponent(fileName(for: path, now: now, sequence: next()))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            guard !FileManager.default.fileExists(atPath: url.path) else { return nil }
            try Data(text.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
