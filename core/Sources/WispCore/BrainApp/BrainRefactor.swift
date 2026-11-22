import Foundation

public struct BrainFileEdit: Sendable, Equatable {
    public var oldPath: String
    public var newPath: String
    public var oldText: String
    public var newText: String
    public var count: Int
}

public struct BrainMovePlan: Sendable, Equatable {
    public var from: String
    public var to: String
    public var isFolder: Bool
    public var edits: [BrainFileEdit]
    public var undownloaded: [String] = []
    public var skipped: [String] = []

    public var isComplete: Bool { undownloaded.isEmpty && skipped.isEmpty }
    public var linkCount: Int { edits.reduce(0) { $0 + $1.count } }
    public var fileCount: Int { edits.count }
}

public enum BrainRefactor {
    public static func plan(root: String, scan: BrainScan, from: String, to: String) throws -> BrainMovePlan {
        let files = BrainFiles(root: root)
        _ = try files.url(from)
        try files.validateNew(to)
        guard let source = scan.entries.first(where: { $0.path == from }) else { throw BrainFilesError.missing(from) }
        if to == from || to.hasPrefix(from + "/") { throw BrainFilesError.outside(to) }
        if files.exists(to), !files.sameFile(from, to) { throw BrainFilesError.exists(to) }

        func relocated(_ path: String) -> String {
            if path == from { return to }
            if path.hasPrefix(from + "/") { return to + path.dropFirst(from.count) }
            return path
        }
        let moved = Dictionary(
            uniqueKeysWithValues: scan.entries.filter { !$0.isFolder && ($0.path == from || $0.path.hasPrefix(from + "/")) }.map { ($0.path, relocated($0.path)) })
        let oldFiles = BrainFileResolver(paths: scan.entries.filter { !$0.isFolder }.map(\.path))
        let newFiles = BrainFileResolver(paths: scan.entries.filter { !$0.isFolder }.map { relocated($0.path) })
        let newCatalog = BrainCatalog(notes: scan.catalog.notes.values.map { moved[$0.path].map($0.moved(to:)) ?? $0 })

        var candidates = Set<String>()
        var needles = Set<String>()
        for path in moved.keys {
            needles.insert((path as NSString).lastPathComponent.lowercased())
            guard BrainText.isMarkdown(path), let note = scan.catalog.notes[path] else { continue }
            candidates.formUnion(scan.catalog.incoming(of: path))
            candidates.insert(path)
            needles.insert(note.stem.lowercased())
            needles.insert(note.title.lowercased())
            for alias in note.aliases { needles.insert(alias.lowercased()) }
        }
        needles.remove("")
        let movesAttachment = moved.keys.contains { !BrainText.isMarkdown($0) || scan.catalog.notes[$0] == nil }
        let bySize = Dictionary(uniqueKeysWithValues: scan.entries.map { ($0.path, $0) })
        let needleData = needles.map { Data($0.utf8) }
        var skipped: [String] = []
        var examined: [String: String] = [:]
        for note in scan.catalog.notes.values where !candidates.contains(note.path) {
            let large = (bySize[note.path]?.size ?? note.size) > Int64(BrainNoteParser.readLimit)
            guard large || movesAttachment else { continue }
            guard let data = try? files.data(note.path), let text = BrainFiles.strictText(data) else {
                skipped.append(note.path)
                continue
            }
            let lowered = Data(text.lowercased().utf8)
            if needleData.contains(where: { lowered.range(of: $0) != nil }) {
                candidates.insert(note.path)
                examined[note.path] = text
            }
        }

        var edits: [BrainFileEdit] = []
        for path in candidates.sorted() {
            if bySize[path]?.isSymlink == true || files.isHardLinked(path) {
                skipped.append(path)
                continue
            }
            guard let data = try? files.data(path) else { continue }
            guard let text = examined[path] ?? BrainFiles.strictText(data) else {
                skipped.append(path)
                continue
            }
            var bytes = Array(text.utf8)
            let occurrences = BrainLinkScanner.scan(bytes, includeFrontmatter: true)
            let newSource = moved[path] ?? path
            var changed = 0
            for occurrence in occurrences.reversed() where !occurrence.name.isEmpty {
                let resolve = { (catalog: BrainCatalog, resolver: BrainFileResolver, source: String) -> String? in
                    occurrence.isAttachment ? resolver.resolve(occurrence.name, from: source) : catalog.resolve(occurrence.name, from: source)
                }
                guard let oldTarget = resolve(scan.catalog, oldFiles, path) else { continue }
                let newTarget = moved[oldTarget] ?? oldTarget
                if resolve(newCatalog, newFiles, newSource) == newTarget { continue }
                let name = linkText(for: newTarget, occurrence: occurrence, source: newSource, catalog: newCatalog, files: newFiles)
                bytes.replaceSubrange(occurrence.nameRange, with: Array(name.utf8))
                changed += 1
            }
            if changed > 0 {
                edits.append(BrainFileEdit(oldPath: path, newPath: newSource, oldText: text, newText: String(decoding: bytes, as: UTF8.self), count: changed))
            }
        }
        let undownloaded = scan.entries.filter { $0.dataless && BrainText.isMarkdown($0.path) }.map(\.path).sorted()
        return BrainMovePlan(from: from, to: to, isFolder: source.isFolder, edits: edits, undownloaded: undownloaded, skipped: Array(Set(skipped)).sorted())
    }

    private static func linkText(for target: String, occurrence: BrainLinkOccurrence, source: String, catalog: BrainCatalog, files: BrainFileResolver) -> String {
        let isNote = catalog.notes[target] != nil && !occurrence.isAttachment
        let keepsSuffix = occurrence.name.lowercased().hasSuffix(".md")
        let full = isNote && !keepsSuffix ? BrainText.withoutMarkdownSuffix(target) : target
        if occurrence.name.hasPrefix("./") || occurrence.name.hasPrefix("../") {
            let relative = relativePath(from: BrainText.parent(of: source), to: full)
            let resolved = isNote ? catalog.resolve(relative, from: source) : files.resolve(relative, from: source)
            return resolved == target ? relative : full
        }
        if occurrence.name.contains("/") { return full }
        let leaf = (full as NSString).lastPathComponent
        let works = isNote ? catalog.resolve(leaf, from: source) == target : files.resolve(leaf, from: source) == target
        return works ? leaf : full
    }

    static func relativePath(from folder: String, to path: String) -> String {
        let base = folder.split(separator: "/").map(String.init)
        let target = path.split(separator: "/").map(String.init)
        var common = 0
        while common < base.count, common < target.count - 1, base[common] == target[common] { common += 1 }
        let ups = Array(repeating: "..", count: base.count - common)
        return (ups + target[common...]).joined(separator: "/")
    }

    public static func applyFresh(_ plan: BrainMovePlan, root: String) throws {
        guard let scan = BrainScanner.scan(root: root) else { throw BrainFilesError.missing(root) }
        let fresh = try Self.plan(root: root, scan: scan, from: plan.from, to: plan.to)
        guard fresh == plan else { throw BrainFilesError.stale(plan.from) }
        try apply(plan, root: root)
    }

    public static func apply(_ plan: BrainMovePlan, root: String) throws {
        let files = BrainFiles(root: root)
        for edit in plan.edits where try files.readStrict(edit.oldPath) != edit.oldText { throw BrainFilesError.stale(edit.oldPath) }
        if files.exists(plan.to), !files.sameFile(plan.from, plan.to) { throw BrainFilesError.exists(plan.to) }

        func relocated(_ path: String) -> String {
            if path == plan.from { return plan.to }
            if path.hasPrefix(plan.from + "/") { return plan.to + path.dropFirst(plan.from.count) }
            return path
        }
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: files.root, create: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        var temporaries: [(url: URL, edit: BrainFileEdit)] = []
        var moveDone = false
        var committed: [BrainFileEdit] = []
        do {
            for (index, edit) in plan.edits.enumerated() {
                let temporary = staging.appendingPathComponent("edit-\(index)")
                try BrainFiles.stage(Data(edit.newText.utf8), at: temporary, attributesFrom: files.url(edit.oldPath))
                temporaries.append((temporary, edit))
            }
            try files.move(plan.from, to: plan.to)
            moveDone = true
            for item in temporaries {
                try BrainFiles.rename(item.url, files.url(item.edit.newPath))
                committed.append(item.edit)
            }
        } catch {
            var failures: [String] = []
            for edit in committed {
                do { try files.write(edit.oldText, to: edit.newPath) } catch { failures.append(edit.newPath) }
            }
            if moveDone {
                do { try files.move(plan.to, to: plan.from) } catch { failures.append(plan.to) }
            }
            if !failures.isEmpty {
                throw BrainFilesError.failed("ERRO: a reversão não terminou. Confira o git do brain; estes itens podem estar alterados: \(failures.joined(separator: ", ")). Causa original: \(error.localizedDescription)")
            }
            throw error
        }
    }
}
