import Foundation

public struct BrainBacklinkContext: Sendable, Equatable {
    public var line: Int
    public var text: String
}

public struct BrainBacklink: Sendable, Equatable, Identifiable {
    public var path: String
    public var title: String
    public var contexts: [BrainBacklinkContext]

    public var id: String { path }
}

public enum BrainBacklinks {
    static let contextLimit = 240

    public static func find(for target: String, catalog: BrainCatalog, files: BrainFiles) -> [BrainBacklink] {
        catalog.incoming(of: target).compactMap { source in
            guard let text = try? files.read(source) else { return nil }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            var seen = Set<Int>()
            var contexts: [BrainBacklinkContext] = []
            for occurrence in BrainLinkScanner.scan(text) where !occurrence.isAttachment && catalog.resolve(occurrence.name, from: source) == target {
                guard seen.insert(occurrence.line).inserted, lines.indices.contains(occurrence.line) else { continue }
                contexts.append(BrainBacklinkContext(line: occurrence.line, text: String(lines[occurrence.line].trimmingCharacters(in: .whitespaces).prefix(contextLimit))))
            }
            return BrainBacklink(path: source, title: catalog.notes[source]?.title ?? BrainText.stem(of: source), contexts: contexts)
        }
    }

    public static func outgoing(text: String, source: String, catalog: BrainCatalog) -> [BrainResolvedLink] {
        var seen = Set<String>()
        var out: [BrainResolvedLink] = []
        for occurrence in BrainLinkScanner.scan(text) where !occurrence.isAttachment {
            let target = catalog.resolve(occurrence.name, from: source)
            let key = (target ?? "?" + occurrence.name.lowercased()) + "#" + occurrence.heading
            guard seen.insert(key).inserted, target != source || !occurrence.heading.isEmpty || !occurrence.name.isEmpty else { continue }
            out.append(BrainResolvedLink(name: occurrence.name, heading: occurrence.heading, target: target))
        }
        return out
    }
}
