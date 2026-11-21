import Foundation

public enum MeetingBrainExportError: Error, LocalizedError, Equatable {
    case outsideBrain(String)

    public var errorDescription: String? {
        switch self {
        case .outsideBrain(let name): "A pasta \(name) do brain aponta para fora do brain; não salvei nada."
        }
    }
}

public enum MeetingBrainExport {
    public static let indexLineLimit = 200

    public static func slug(_ title: String, limit: Int = 48) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "pt_BR"))
        var out = ""
        var pendingDash = false
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        let cut = String(out.prefix(limit)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cut.isEmpty ? "reuniao" : cut
    }

    public static func fileName(title: String, startedAt: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HH'h'mm'm'"
        return "\(formatter.string(from: startedAt))-\(slug(title))"
    }

    @discardableResult
    public static func save(
        note: URL, title: String, startedAt: Date, brain: URL, timeZone: TimeZone = .current, fileManager: FileManager = .default
    ) throws -> URL {
        let folder = brain.appendingPathComponent("meetings", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = brain.resolvingSymlinksInPath().path
        guard folder.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw MeetingBrainExportError.outsideBrain("meetings") }
        let base = fileName(title: title, startedAt: startedAt, timeZone: timeZone)
        var suffix = 1
        var target = folder.appendingPathComponent("\(base).md")
        while fileManager.fileExists(atPath: target.path) {
            suffix += 1
            target = folder.appendingPathComponent("\(base)-\(suffix).md")
        }
        try fileManager.copyItem(at: note, to: target)
        let index = folder.appendingPathComponent("meetings-index.md")
        if fileManager.fileExists(atPath: index.path) {
            guard index.resolvingSymlinksInPath().path.hasPrefix(root + "/") else { throw MeetingBrainExportError.outsideBrain("meetings-index.md") }
            let existing = (try? String(contentsOf: index, encoding: .utf8)) ?? ""
            let line = indexLine(name: target.deletingPathExtension().lastPathComponent, title: title)
            let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            try (existing + separator + line + "\n").write(to: index, atomically: true, encoding: .utf8)
        }
        return target
    }

    public static func sanitizedTitle(_ title: String) -> String {
        var out = title
        for bad in ["[[", "]]", "|", "\r", "\n"] { out = out.replacingOccurrences(of: bad, with: " ") }
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public static func indexLine(name: String, title: String) -> String {
        let line = "- [[\(name)]] — \(sanitizedTitle(title))"
        guard line.count > indexLineLimit else { return line }
        return String(line.prefix(indexLineLimit - 1)) + "…"
    }
}
