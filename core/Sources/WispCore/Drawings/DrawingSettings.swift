import Foundation

public struct ExcalidrawPluginSettings: Equatable, Sendable {
    public static let pluginFolder = ".obsidian/plugins/obsidian-excalidraw-plugin"

    public var folder = "Excalidraw"
    public var filenamePrefix = "Drawing "
    public var dateFormat = "YYYY-MM-DD HH.mm.ss"
    public var useExcalidrawExtension = true
    public var compress = true
    public var compatibilityMode = false
    public var pluginVersion = ExcalidrawFile.fallbackPluginVersion

    public init() {}

    public static func load(brain: URL) -> ExcalidrawPluginSettings {
        var settings = ExcalidrawPluginSettings()
        let base = brain.appendingPathComponent(pluginFolder, isDirectory: true)
        if let data = try? Data(contentsOf: base.appendingPathComponent("data.json")), let json = try? JSONValue.parse(data) {
            if let folder = json["folder"]?.stringValue { settings.folder = folder }
            if let prefix = json["drawingFilenamePrefix"]?.stringValue { settings.filenamePrefix = prefix }
            if let format = json["drawingFilenameDateTime"]?.stringValue { settings.dateFormat = format }
            if let value = json["useExcalidrawExtension"]?.boolValue { settings.useExcalidrawExtension = value }
            if let value = json["compress"]?.boolValue { settings.compress = value }
            if let value = json["compatibilityMode"]?.boolValue { settings.compatibilityMode = value }
        }
        if let data = try? Data(contentsOf: base.appendingPathComponent("manifest.json")),
           let version = (try? JSONValue.parse(data))?["version"]?.stringValue {
            settings.pluginVersion = version
        }
        return settings
    }

    public func fileName(at date: Date, timeZone: TimeZone = .current) -> String {
        let stamp = dateFormat.isEmpty ? "" : Self.format(date, pattern: dateFormat, timeZone: timeZone)
        let suffix = compatibilityMode ? ".excalidraw" : (useExcalidrawExtension ? ".excalidraw.md" : ".md")
        return filenamePrefix + stamp + suffix
    }

    static func format(_ date: Date, pattern: String, timeZone: TimeZone) -> String {
        var icu = ""
        var rest = Substring(pattern)
        let tokens: [(String, String)] = [("YYYY", "yyyy"), ("YY", "yy"), ("MMMM", "MMMM"), ("MMM", "MMM"), ("MM", "MM"), ("DD", "dd"), ("HH", "HH"), ("hh", "hh"), ("mm", "mm"), ("ss", "ss"), ("SSS", "SSS"), ("A", "a")]
        while let first = rest.first {
            if first == "[", let close = rest.firstIndex(of: "]") {
                icu += "'" + rest[rest.index(after: rest.startIndex)..<close].replacingOccurrences(of: "'", with: "''") + "'"
                rest = rest[rest.index(after: close)...]
            } else if let token = tokens.first(where: { rest.hasPrefix($0.0) }) {
                icu += token.1
                rest = rest.dropFirst(token.0.count)
            } else if first.isLetter {
                icu += "'\(first)'"
                rest = rest.dropFirst()
            } else {
                icu.append(first)
                rest = rest.dropFirst()
            }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = icu
        return formatter.string(from: date)
    }
}

public enum NewDrawing {
    public static func uniqueURL(folder: URL, fileName: String) -> URL {
        let fileManager = FileManager.default
        var candidate = folder.appendingPathComponent(fileName)
        let suffix = fileName.hasSuffix(".excalidraw.md") ? ".excalidraw.md" : ".\((fileName as NSString).pathExtension)"
        let stem = String(fileName.dropLast(suffix.count))
        var counter = 0
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(stem)_\(counter)\(suffix)")
            counter += 1
        }
        return candidate
    }

    public static func create(brain: URL, settings: ExcalidrawPluginSettings? = nil, now: Date = Date(), timeZone: TimeZone = .current) throws -> URL {
        let settings = settings ?? ExcalidrawPluginSettings.load(brain: brain)
        let folder = settings.folder.isEmpty ? brain : brain.appendingPathComponent(settings.folder, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(folder: folder, fileName: settings.fileName(at: now, timeZone: timeZone))
        let file = ExcalidrawFile.blank(pluginVersion: settings.pluginVersion, compressed: settings.compress, plain: settings.compatibilityMode)
        try file.write(to: url)
        return url
    }

    public static func createCanvas(in folder: URL, named name: String = "Sem título") throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = uniqueURL(folder: folder, fileName: "\(name).canvas")
        try JSONCanvas.blank().write(to: url)
        return url
    }
}

public enum DrawingAttachments {
    public static func confined(_ url: URL, to root: URL) -> URL? {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(base.hasSuffix("/") ? base : base + "/") else { return nil }
        return resolved
    }

    public static func root(for file: URL, vaultRoot: URL?) -> URL {
        vaultRoot ?? file.deletingLastPathComponent()
    }

    public static func resolve(target: String, near file: URL, vaultRoot: URL?) -> URL? {
        let fileManager = FileManager.default
        let root = root(for: file, vaultRoot: vaultRoot)
        var candidates = [file.deletingLastPathComponent().appendingPathComponent(target)]
        if let vaultRoot { candidates.append(vaultRoot.appendingPathComponent(target)) }
        for candidate in candidates where fileManager.fileExists(atPath: candidate.path) {
            if let safe = confined(candidate, to: root) { return safe }
        }
        return nil
    }

    public static func resolve(target: String, near file: URL, vaultRoot: URL?, index: DrawingNameIndex) async -> URL? {
        if let direct = resolve(target: target, near: file, vaultRoot: vaultRoot) { return direct }
        guard let vaultRoot else { return nil }
        let name = (target as NSString).lastPathComponent
        guard let found = await index.url(forName: name, root: vaultRoot) else { return nil }
        return confined(found, to: vaultRoot)
    }

    public static func uniqueURL(forPastedImage mimeType: String, in folder: URL, now: Date = Date(), timeZone: TimeZone = .current) -> URL {
        let stamp = ExcalidrawPluginSettings.format(now, pattern: "YYYYMMDDHHmmss_SSS", timeZone: timeZone)
        return NewDrawing.uniqueURL(folder: folder, fileName: "Pasted Image \(stamp).\(ExcalidrawFile.fileExtension(forMimeType: mimeType))")
    }
}

public actor DrawingNameIndex {
    public static let shared = DrawingNameIndex()

    private struct Snapshot {
        var built: Date
        var names: [String: URL]
    }

    private var snapshots: [String: Snapshot] = [:]
    private let refreshAfter: TimeInterval

    public init(refreshAfter: TimeInterval = 30) {
        self.refreshAfter = refreshAfter
    }

    public func url(forName name: String, root: URL) -> URL? {
        let key = root.standardizedFileURL.path
        if let snapshot = snapshots[key], let hit = snapshot.names[name] { return hit }
        if let snapshot = snapshots[key], Date().timeIntervalSince(snapshot.built) < refreshAfter { return nil }
        let rebuilt = Snapshot(built: Date(), names: Self.scan(root))
        snapshots[key] = rebuilt
        return rebuilt.names[name]
    }

    private static func scan(_ root: URL) -> [String: URL] {
        var names: [String: URL] = [:]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return names }
        for case let url as URL in walker where names[url.lastPathComponent] == nil {
            names[url.lastPathComponent] = url
        }
        return names
    }
}

public enum DrawingRecovery {
    public static func recoveryURL(for url: URL, now: Date = Date(), timeZone: TimeZone = .current) -> URL {
        let name = url.lastPathComponent
        let suffix = [".excalidraw.md", ".excalidraw", ".canvas"].first { name.lowercased().hasSuffix($0) } ?? ".\(url.pathExtension)"
        let stem = String(name.dropLast(suffix.count))
        let stamp = ExcalidrawPluginSettings.format(now, pattern: "YYYY-MM-DD HH.mm.ss", timeZone: timeZone)
        return NewDrawing.uniqueURL(folder: url.deletingLastPathComponent(), fileName: "\(stem) (conflito Wisp \(stamp))\(suffix)")
    }
}
