import Foundation

public struct BrainFileResolver: Sendable {
    private var byName: [String: [String]] = [:]
    public let paths: [String]

    public init(paths: [String]) {
        self.paths = paths
        for path in paths { byName[(path as NSString).lastPathComponent.lowercased(), default: []].append(path) }
    }

    public func resolve(_ name: String, from source: String) -> String? {
        var key = name.lowercased()
        while key.hasPrefix("/") { key.removeFirst() }
        guard !key.isEmpty else { return nil }
        let candidates = key.hasSuffix(".excalidraw") ? [key, key + ".md"] : [key]
        let pool = candidates.flatMap { candidate -> [String] in
            let named = byName[(candidate as NSString).lastPathComponent] ?? []
            guard candidate.contains("/") else { return named }
            return named.filter { $0.lowercased() == candidate || $0.lowercased().hasSuffix("/" + candidate) }
        }
        guard !pool.isEmpty else { return nil }
        let home = BrainText.parent(of: source)
        return pool.min { a, b in
            let keyA = (BrainText.parent(of: a) != home ? 1 : 0, a.filter { $0 == "/" }.count, a)
            let keyB = (BrainText.parent(of: b) != home ? 1 : 0, b.filter { $0 == "/" }.count, b)
            return keyA < keyB
        }
    }
}
