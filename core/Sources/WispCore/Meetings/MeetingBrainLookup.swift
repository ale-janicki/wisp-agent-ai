import Foundation

public struct BrainHit: Equatable, Identifiable, Sendable {
    public var path: String
    public var title: String
    public var snippet: String

    public var id: String { path }

    public init(path: String, title: String, snippet: String) {
        self.path = path
        self.title = title
        self.snippet = snippet
    }

    public func url(root: URL) -> URL? {
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(base.path + "/"), FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }
}

public struct BrainSearchCLI: Sendable {
    public static let snippetLimit = 220

    public var run: @Sendable ([String]) -> CommandOutput?

    public init(run: @escaping @Sendable ([String]) -> CommandOutput?) {
        self.run = run
    }

    public func isAvailable() -> Bool {
        guard let output = run(["brain", "search", "--help"]) else { return false }
        return output.status == 0 && !output.timedOut
    }

    public func search(_ query: String, root: String, limit: Int) -> [BrainHit] {
        guard !query.hasPrefix("-"), let output = run(["brain", "search", query, "--root", root, "--limit", String(limit)]),
              output.status == 0, !output.timedOut else { return [] }
        return Self.parse(output.stdout, limit: limit)
    }

    public static func parse(_ data: Data, limit: Int) -> [BrainHit] {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var rows = object as? [[String: Any]] ?? []
        if let dictionary = object as? [String: Any] {
            rows = ["results", "hits", "notas", "notes"].lazy.compactMap { dictionary[$0] as? [[String: Any]] }.first ?? []
        }
        return rows.prefix(limit).compactMap { row in
            guard let path = ["path", "arquivo", "file"].lazy.compactMap({ row[$0] as? String }).first, !path.isEmpty else { return nil }
            let title = ["title", "titulo"].lazy.compactMap { row[$0] as? String }.first ?? (path as NSString).lastPathComponent
            let snippet = ["snippet", "trecho", "excerpt"].lazy.compactMap { row[$0] as? String }.first ?? ""
            let flat = snippet.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return BrainHit(path: path, title: title, snippet: String(flat.prefix(snippetLimit)))
        }
    }
}
