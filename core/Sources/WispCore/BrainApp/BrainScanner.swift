import Foundation

public struct BrainFileEntry: Sendable, Equatable, Identifiable {
    public var path: String
    public var isFolder: Bool
    public var modified: Double
    public var size: Int64
    public var dataless: Bool
    public var isSymlink: Bool

    public var id: String { path }

    public init(path: String, isFolder: Bool, modified: Double = 0, size: Int64 = 0, dataless: Bool = false, isSymlink: Bool = false) {
        self.path = path
        self.isFolder = isFolder
        self.modified = modified
        self.size = size
        self.dataless = dataless
        self.isSymlink = isSymlink
    }
}

public struct BrainScan: Sendable {
    public var catalog: BrainCatalog
    public var entries: [BrainFileEntry]
    public var reused: Int
    public var read: Int

    public init(catalog: BrainCatalog, entries: [BrainFileEntry], reused: Int = 0, read: Int = 0) {
        self.catalog = catalog
        self.entries = entries
        self.reused = reused
        self.read = read
    }
}

public enum BrainNoteParser {
    public static let readLimit = 128 * 1024
    static let binaryProbe = 8192

    public static func parse(_ bytes: [UInt8], path: String, modified: Double = 0, size: Int64 = 0) -> BrainNote? {
        if bytes.prefix(binaryProbe).contains(0) { return nil }
        let frontLength = BrainLinkScanner.frontmatterLength(in: bytes)
        var aliases: [String] = [], tags: [String] = [], status = ""
        if frontLength > 0 {
            let document = BrainDocument(String(decoding: bytes[0..<frontLength], as: UTF8.self))
            aliases = document.list("aliases")
            tags = document.list("tags").map { BrainText.fold($0.hasPrefix("#") ? String($0.dropFirst()) : $0) }
            if case .text(let value) = document.property("status") { status = BrainText.fold(value) }
        }
        var title = ""
        var inline = Set<String>()
        scanProse(bytes, from: frontLength, title: &title, tags: &inline)
        let links = BrainLinkScanner.scan(bytes, includeFrontmatter: true).filter { !$0.isAttachment }.map { BrainLinkRef(name: $0.name, heading: $0.heading) }
        var seen = Set<String>()
        let unique = links.filter { seen.insert($0.name + "\u{0}" + $0.heading).inserted }
        return BrainNote(
            path: path, title: title, aliases: aliases, tags: tags, inlineTags: inline.sorted(), status: status, links: unique,
            modified: modified, size: size)
    }

    private static func scanProse(_ bytes: [UInt8], from offset: Int, title: inout String, tags: inout Set<String>) {
        var fence: ArraySlice<UInt8>?
        var start = offset
        while start < bytes.count {
            var end = start
            while end < bytes.count && bytes[end] != 0x0A { end += 1 }
            let line = bytes[start..<end]
            let lead = line.drop { $0 == 0x20 || $0 == 0x09 }
            let marker = lead.prefix(3)
            if fence == nil, marker.elementsEqual([0x60, 0x60, 0x60]) || marker.elementsEqual([0x7E, 0x7E, 0x7E]) {
                fence = marker
            } else if let open = fence {
                if lead.starts(with: open) { fence = nil }
            } else {
                if title.isEmpty, let heading = firstLevelHeading(line) { title = heading }
                collectTags(line, into: &tags)
            }
            start = end + 1
        }
    }

    private static func firstLevelHeading(_ line: ArraySlice<UInt8>) -> String? {
        guard line.first == 0x23, line.count > 1, line[line.startIndex + 1] == 0x20 || line[line.startIndex + 1] == 0x09 else { return nil }
        var text = BrainText.trimmed(line.dropFirst())
        while text.last == 0x23 { text = text.dropLast() }
        text = BrainText.trimmed(text)
        return text.isEmpty ? nil : String(decoding: text, as: UTF8.self)
    }

    private static func collectTags(_ line: ArraySlice<UInt8>, into tags: inout Set<String>) {
        var i = line.startIndex
        var inCode = false
        while i < line.endIndex {
            let byte = line[i]
            if byte == 0x60 {
                inCode.toggle()
            } else if byte == 0x23, !inCode, i == line.startIndex || line[i - 1] == 0x20 || line[i - 1] == 0x09 {
                var j = i + 1
                var hasLetter = false
                while j < line.endIndex, isTagByte(line[j]) {
                    if !(line[j] >= 0x30 && line[j] <= 0x39) && line[j] != 0x2F && line[j] != 0x2D && line[j] != 0x5F { hasLetter = true }
                    j += 1
                }
                if hasLetter, j > i + 1 {
                    tags.insert(BrainText.fold(String(decoding: line[(i + 1)..<j], as: UTF8.self)))
                }
                i = j
                continue
            }
            i += 1
        }
    }

    private static func isTagByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || byte == 0x5F || byte == 0x2D || byte == 0x2F || byte >= 0x80
    }
}

public enum BrainScanner {
    static let skippedFolders: Set<String> = ["arquivos"]
    static let hiddenFromTree: Set<String> = [".git", ".obsidian", ".trash"]
    static let datalessFlag: UInt32 = 0x4000_0000

    private final class Slots: @unchecked Sendable {
        private let lock = NSLock()
        var notes: [BrainNote?]

        init(count: Int) { notes = Array(repeating: nil, count: count) }

        func set(_ index: Int, _ note: BrainNote?) { lock.withLock { notes[index] = note } }
    }

    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func scan(root: String, previous: BrainCatalog? = nil) -> BrainScan? {
        let base = canonical(MemorySearch.resolvedRoot(root))
        let prefix = base.hasSuffix("/") ? base : base + "/"
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: base, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                  at: URL(fileURLWithPath: base, isDirectory: true), includingPropertiesForKeys: nil, options: [.skipsPackageDescendants])
        else { return nil }

        var entries: [BrainFileEntry] = []
        var pending: [(path: String, modified: Double, size: Int64)] = []
        var kept: [BrainNote] = []
        var reused = 0
        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            var info = stat()
            guard lstat(url.path, &info) == 0 else { continue }
            let isFolder = info.st_mode & S_IFMT == S_IFDIR
            if name.hasPrefix(".") {
                if isFolder { enumerator.skipDescendants() }
                continue
            }
            guard url.path.hasPrefix(prefix) else { continue }
            let relative = String(url.path.dropFirst(prefix.count))
            let modified = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
            if isFolder {
                entries.append(BrainFileEntry(path: relative, isFolder: true, modified: modified))
                continue
            }
            let isLink = info.st_mode & S_IFMT == S_IFLNK
            if isLink {
                var target = stat()
                guard stat(url.path, &target) == 0, target.st_mode & S_IFMT == S_IFREG else { continue }
            } else if info.st_mode & S_IFMT != S_IFREG {
                continue
            }
            let dataless = info.st_flags & datalessFlag != 0
            entries.append(BrainFileEntry(path: relative, isFolder: false, modified: modified, size: Int64(info.st_size), dataless: dataless, isSymlink: isLink))
            guard BrainText.isMarkdown(name), !relative.split(separator: "/").dropLast().contains(where: { skippedFolders.contains(String($0)) }) else { continue }
            if dataless { continue }
            if let old = previous?.notes[relative], old.modified == modified, old.size == Int64(info.st_size) {
                kept.append(old)
                reused += 1
            } else {
                pending.append((relative, modified, Int64(info.st_size)))
            }
        }

        let slots = Slots(count: pending.count)
        let work = pending
        let top = base
        DispatchQueue.concurrentPerform(iterations: work.count) { i in
            let item = work[i]
            guard let handle = FileHandle(forReadingAtPath: top + "/" + item.path) else { return }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: BrainNoteParser.readLimit) else { return }
            slots.set(i, BrainNoteParser.parse([UInt8](data), path: item.path, modified: item.modified, size: item.size))
        }
        let parsed = slots.notes.compactMap { $0 }
        return BrainScan(catalog: BrainCatalog(notes: kept + parsed), entries: entries, reused: reused, read: parsed.count)
    }
}
