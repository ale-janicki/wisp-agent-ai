import Foundation

public enum BrainFileKind: Sendable, Equatable {
    case note, drawing, image, other

    public static func of(_ path: String) -> BrainFileKind {
        let lowered = path.lowercased()
        if lowered.hasSuffix(".excalidraw.md") || lowered.hasSuffix(".excalidraw") || lowered.hasSuffix(".canvas") { return .drawing }
        if lowered.hasSuffix(".md") { return .note }
        return BrainEmbed.imageExtensions.contains((lowered as NSString).pathExtension) ? .image : .other
    }
}

public struct BrainTreeRow: Sendable, Equatable, Identifiable {
    public var path: String
    public var name: String
    public var depth: Int
    public var isFolder: Bool
    public var expanded: Bool
    public var childCount: Int

    public var id: String { path }
}

public enum BrainTree {
    public static func displayName(_ path: String, isFolder: Bool) -> String {
        let name = (path as NSString).lastPathComponent
        return isFolder ? name : BrainText.withoutMarkdownSuffix(name)
    }

    public struct Index: Sendable {
        fileprivate var children: [String: [BrainFileEntry]] = [:]

        public init(entries: [BrainFileEntry]) {
            var names: [String: String] = [:]
            for entry in entries {
                children[BrainText.parent(of: entry.path), default: []].append(entry)
                names[entry.path] = BrainTree.displayName(entry.path, isFolder: entry.isFolder)
            }
            for key in children.keys {
                children[key]?.sort { a, b in
                    if a.isFolder != b.isFolder { return a.isFolder }
                    let order = names[a.path]!.compare(names[b.path]!, options: [.caseInsensitive, .numeric])
                    return order == .orderedSame ? a.path < b.path : order == .orderedAscending
                }
            }
        }

        public func rows(expanded: Set<String>) -> [BrainTreeRow] {
            var rows: [BrainTreeRow] = []
            func walk(_ parent: String, depth: Int) {
                for entry in children[parent] ?? [] {
                    let open = entry.isFolder && expanded.contains(entry.path)
                    rows.append(BrainTreeRow(
                        path: entry.path, name: BrainTree.displayName(entry.path, isFolder: entry.isFolder), depth: depth, isFolder: entry.isFolder,
                        expanded: open, childCount: children[entry.path]?.count ?? 0))
                    if open { walk(entry.path, depth: depth + 1) }
                }
            }
            walk("", depth: 0)
            return rows
        }
    }

    public static func rows(entries: [BrainFileEntry], expanded: Set<String>) -> [BrainTreeRow] {
        Index(entries: entries).rows(expanded: expanded)
    }

    public static func ancestors(of path: String) -> [String] {
        var out: [String] = []
        var current = BrainText.parent(of: path)
        while !current.isEmpty {
            out.append(current)
            current = BrainText.parent(of: current)
        }
        return out
    }

    public static func uniquePath(_ wanted: String, existing: Set<String>) -> String {
        let lowered = Set(existing.map { $0.lowercased() })
        guard lowered.contains(wanted.lowercased()) else { return wanted }
        let ext = (wanted as NSString).pathExtension
        let base = ext.isEmpty ? wanted : String(wanted.dropLast(ext.count + 1))
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !lowered.contains(candidate.lowercased()) { return candidate }
            n += 1
        }
    }
}
