import Foundation

/// A file already copied where the agent can read it, as it goes in the prompt.
public struct StagedAttachment: Equatable, Sendable {
    public var path: String
    public var name: String
    public var bytes: Int

    public init(path: String, name: String, bytes: Int) {
        self.path = path
        self.name = name
        self.bytes = bytes
    }
}

/// The attachment block the Telegram bot writes for a phone upload, and Wisp writes for its own:
/// `[o <user> enviou N arquivo(s) pelo <origem>, ja salvos nesta maquina:\n- <path> (<name>, <bytes> bytes)…]\n\n<caption>`.
/// Wisp composes it byte for byte like the bot (`bloco_anexos` in bot.py), so a linked echo matches the transcript.
public struct MessageAttachments: Equatable, Sendable {
    public enum Item: Equatable, Sendable {
        case file(path: String, name: String, bytes: Int)
        case failed(label: String)
    }

    public var origin: String
    public var items: [Item]
    public var caption: String?

    public static let noCaption = "(sem texto — veja o que é e me diga)"
    private static let headPrefix = "[o "
    private static let headEnviou = " enviou "
    public static let defaultUser = "usuario"
    private static let headMiddle = " arquivo(s) pelo "
    private static let headSuffix = ", ja salvos nesta maquina:"
    private static let failedMarker = ": nao consegui baixar"
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "gif", "webp"]

    public static func isImage(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    /// A text that starts like the block but does not parse: no items (so no path ever shows), just the caption.
    public static func unparsed(_ text: String) -> MessageAttachments? {
        guard isBlockHead(text), parse(text) == nil else { return nil }
        let rest = text.range(of: "]\n\n").map { text[$0.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return MessageAttachments(origin: "", items: [], caption: rest.isEmpty || isPlaceholder(rest) ? nil : rest)
    }

    /// What names a new topic when the first message has no text.
    public static func firstMessageName(caption: String, names: [String]) -> String {
        guard caption.isEmpty else { return caption }
        return names.allSatisfy(isImage) ? "foto" : "arquivo"
    }

    /// One line for previews: "2 fotos · 1 arquivo · <caption>".
    public var summary: String {
        let photos = items.filter { if case .file(_, let name, _) = $0 { Self.isImage(name) } else { false } }.count
        let others = items.count - photos
        var parts: [String] = items.isEmpty ? ["anexos"] : []
        if photos > 0 { parts.append(photos == 1 ? "1 foto" : "\(photos) fotos") }
        if others > 0 { parts.append(others == 1 ? "1 arquivo" : "\(others) arquivos") }
        if let caption { parts.append(caption) }
        return parts.joined(separator: " · ")
    }

    /// The name without the `wisp-<8 hex>-` that staging puts in front.
    public static func displayName(_ name: String) -> String {
        let parts = name.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "wisp", parts[1].count == 8, parts[1].allSatisfy(\.isHexDigit), !parts[2].isEmpty else {
            return name
        }
        return String(parts[2])
    }

    /// The first line has the full shape `[o <name> enviou <digits> arquivo(s) pelo Telegram|Wisp`; ordinary text that
    /// only starts with "[o " does not count.
    private static func isBlockHead(_ text: String) -> Bool {
        guard text.hasPrefix(headPrefix) else { return false }
        let head = text.prefix { $0 != "\n" }.dropFirst(headPrefix.count)
        var from = head.startIndex
        while let who = head.range(of: headEnviou, range: from..<head.endIndex) {
            let rest = head[who.upperBound...]
            let digits = rest.prefix(while: \.isASCII).prefix(while: \.isNumber)
            let after = rest.dropFirst(digits.count)
            if !digits.isEmpty, after.hasPrefix(headMiddle), ["Telegram", "Wisp"].contains(where: { after.dropFirst(headMiddle.count).hasPrefix($0) }) {
                return true
            }
            from = who.upperBound
        }
        return false
    }

    public static func compose(origin: String, files: [StagedAttachment], caption: String, user: String? = nil) -> String {
        let name = user?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let who = name.isEmpty ? defaultUser : name
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = files.map { "- \($0.path) (\($0.name), \($0.bytes) bytes)" }
        return "\(headPrefix)\(who)\(headEnviou)\(files.count)\(headMiddle)\(origin)\(headSuffix)\n"
            + lines.joined(separator: "\n") + "]\n\n" + (trimmed.isEmpty ? noCaption : trimmed)
    }

    public static func parse(_ text: String) -> MessageAttachments? {
        let lines = text.components(separatedBy: "\n")
        guard let head = lines.first, head.hasPrefix(headPrefix), head.hasSuffix(headSuffix),
              let who = head.dropFirst(headPrefix.count).range(of: headEnviou) else { return nil }
        let middle = head.dropFirst(headPrefix.count)[who.upperBound...].dropLast(headSuffix.count)
        guard let split = middle.range(of: headMiddle), let count = Int(middle[..<split.lowerBound]), count > 0 else { return nil }
        let origin = String(middle[split.upperBound...])

        var items: [Item] = []
        var index = 1
        var closed = false
        while index < lines.count, !closed {
            var line = lines[index]
            guard line.hasPrefix("- ") else { return nil }
            if line.hasSuffix("]") {
                line.removeLast()
                closed = true
            }
            items.append(item(String(line.dropFirst(2))))
            index += 1
        }
        guard closed, items.count == count else { return nil }
        let rest = lines[index...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let caption = rest.isEmpty || isPlaceholder(rest) ? nil : rest
        return MessageAttachments(origin: origin, items: items, caption: caption)
    }

    private static func isPlaceholder(_ caption: String) -> Bool {
        caption == noCaption || (caption.hasPrefix("(sem texto") && caption.hasSuffix(")") && !caption.contains("\n"))
    }

    /// `<path> (<name>, <bytes> bytes)`; a name may hold " (", so the split is the one whose path ends with the name.
    private static func item(_ body: String) -> Item {
        let bytesSuffix = " bytes)"
        guard body.hasPrefix("/"), body.hasSuffix(bytesSuffix) else {
            let label = body.range(of: failedMarker).map { String(body[..<$0.lowerBound]) } ?? body
            return .failed(label: fileName(label))
        }
        let inner = body.dropLast(bytesSuffix.count)
        guard let comma = inner.range(of: ", ", options: .backwards), let bytes = Int(inner[comma.upperBound...]) else {
            return .failed(label: fileName(body))
        }
        let pathAndName = inner[..<comma.lowerBound]
        var cuts: [Range<Substring.Index>] = []
        var from = pathAndName.startIndex
        while let cut = pathAndName.range(of: " (", range: from..<pathAndName.endIndex) {
            cuts.append(cut)
            from = cut.upperBound
        }
        let chosen = cuts.first { cut in
            let path = String(pathAndName[..<cut.lowerBound])
            return (path as NSString).lastPathComponent.hasSuffix(String(pathAndName[cut.upperBound...]))
        } ?? cuts.last
        guard let chosen else { return .failed(label: fileName(body)) }
        return .file(path: String(pathAndName[..<chosen.lowerBound]), name: String(pathAndName[chosen.upperBound...]), bytes: bytes)
    }
}

/// Only the last path component of a line that did not parse: a path never reaches the screen.
private func fileName(_ line: String) -> String {
    let head = line.range(of: " (").map { String(line[..<$0.lowerBound]) } ?? line
    return (head as NSString).lastPathComponent
}

/// Copies what the user picked into `<root>/<yyyy-MM-dd>/` (the bot's attachments folder) under unique names.
public enum AttachmentStaging {
    /// Symlinks resolved first; only regular files pass (folders, `.app`, `.photoslibrary` and other packages do not).
    public static func regularFiles(_ urls: [URL]) -> (files: [URL], refused: [String]) {
        var files: [URL] = []
        var refused: [String] = []
        for url in urls {
            let values = realPath(url.path).flatMap { try? URL(fileURLWithPath: $0).resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) }
            if let values, values.isRegularFile == true, values.isSymbolicLink != true, let real = realPath(url.path) {
                files.append(URL(fileURLWithPath: real))
            } else {
                refused.append(url.lastPathComponent)
            }
        }
        return (files, refused)
    }

    public static func refusal(_ names: [String]) -> String {
        "Não anexei \(names.joined(separator: ", ")): só dá para anexar arquivos, não pastas nem pacotes."
    }

    /// realpath(3), the same answer as the bot's `Path.resolve()` (URL.resolvingSymlinksInPath drops `/private`).
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    public static func stage(_ sources: [URL], into root: URL, on day: Date = Date()) throws -> [StagedAttachment] {
        let fm = FileManager.default
        let made = root.appendingPathComponent(dayName(day), isDirectory: true)
        try fm.createDirectory(at: made, withIntermediateDirectories: true)
        let folder = URL(fileURLWithPath: realPath(made.path) ?? made.path, isDirectory: true)
        var staged: [StagedAttachment] = []
        do {
            for source in sources {
                guard let real = realPath(source.path) else { throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path]) }
                let token = UUID().uuidString.prefix(8).lowercased()
                let name = "wisp-\(token)-\(source.lastPathComponent)"
                let target = folder.appendingPathComponent(name)
                try fm.copyItem(at: URL(fileURLWithPath: real), to: target)
                let bytes = (try fm.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?.intValue ?? 0
                staged.append(StagedAttachment(path: target.path, name: name, bytes: bytes))
            }
        } catch {
            for item in staged { try? fm.removeItem(atPath: item.path) }
            throw error
        }
        return staged
    }

    /// Local day, like the bot's `time.strftime("%Y-%m-%d")`.
    static func dayName(_ day: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: .current, from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
