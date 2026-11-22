import Foundation

public enum MomentFormat {
    private static let tokens: [(String, String)] = [
        ("YYYY", "yyyy"), ("YY", "yy"), ("MMMM", "MMMM"), ("MMM", "MMM"), ("MM", "MM"), ("M", "M"),
        ("DDDD", "DDD"), ("DD", "dd"), ("Do", "d"), ("D", "d"), ("dddd", "EEEE"), ("ddd", "EEE"),
        ("HH", "HH"), ("H", "H"), ("hh", "hh"), ("h", "h"), ("mm", "mm"), ("m", "m"), ("ss", "ss"), ("s", "s"),
        ("A", "a"), ("a", "a"), ("WW", "ww"), ("W", "w"), ("ww", "ww"), ("w", "w"), ("gggg", "YYYY"), ("GGGG", "YYYY"),
    ]

    public static let defaultLocale = Locale(identifier: "en_US")

    public static func ordinal(_ day: Int) -> String {
        let tens = day % 100
        if (11...13).contains(tens) { return "\(day)th" }
        switch day % 10 {
        case 1: return "\(day)st"
        case 2: return "\(day)nd"
        case 3: return "\(day)rd"
        default: return "\(day)th"
        }
    }

    public static func dateFormat(_ moment: String, day: Int? = nil) -> String {
        var out = ""
        var index = moment.startIndex
        while index < moment.endIndex {
            if moment[index] == "[" , let close = moment[index...].firstIndex(of: "]") {
                let literal = moment[moment.index(after: index)..<close]
                out += "'" + literal.replacingOccurrences(of: "'", with: "''") + "'"
                index = moment.index(after: close)
                continue
            }
            if moment[index...].hasPrefix("Do"), let day {
                out += "'" + ordinal(day) + "'"
                index = moment.index(index, offsetBy: 2)
                continue
            }
            if let (token, pattern) = tokens.first(where: { moment[index...].hasPrefix($0.0) }) {
                out += pattern
                index = moment.index(index, offsetBy: token.count)
                continue
            }
            let character = moment[index]
            out += character.isLetter ? "'\(character)'" : (character == "'" ? "''" : String(character))
            index = moment.index(after: index)
        }
        return out
    }

    public static func string(from date: Date, format: String, locale: Locale = MomentFormat.defaultLocale, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = dateFormat(format, day: calendar.component(.day, from: date))
        return formatter.string(from: date)
    }
}

public struct BrainDailyConfig: Sendable, Equatable {
    public var folder: String
    public var format: String
    public var template: String?

    public static let defaultFormat = "YYYY-MM-DD"

    public init(folder: String = "", format: String = defaultFormat, template: String? = nil) {
        self.folder = folder
        self.format = format
        self.template = template
    }

    public static func load(root: String, notes: [String]) -> BrainDailyConfig {
        let base = URL(fileURLWithPath: MemorySearch.resolvedRoot(root), isDirectory: true)
        let daily = json(base.appendingPathComponent(".obsidian/daily-notes.json"))
        let templates = json(base.appendingPathComponent(".obsidian/templates.json"))
        var config = BrainDailyConfig()
        if let daily {
            config.folder = clean(daily["folder"] as? String ?? "")
            if let format = daily["format"] as? String, !format.isEmpty { config.format = format }
            if let template = daily["template"] as? String, !template.isEmpty { config.template = normalize(template) }
        } else if let inferred = infer(notes: notes) {
            config = inferred
        }
        if config.template == nil {
            let folder = clean(templates?["folder"] as? String ?? "")
            let candidates = folder.isEmpty ? Array(Set(notes.map { BrainText.parent(of: $0) }.filter { $0.lowercased() == "templates" })) : [folder]
            config.template = candidates.lazy.map { BrainText.join($0, "daily.md") }.first { notes.contains($0) }
        }
        return config
    }

    public static func templatesFolder(root: String, notes: [String]) -> String? {
        let base = URL(fileURLWithPath: MemorySearch.resolvedRoot(root), isDirectory: true)
        if let folder = json(base.appendingPathComponent(".obsidian/templates.json"))?["folder"] as? String, !clean(folder).isEmpty { return clean(folder) }
        return Set(notes.map { BrainText.parent(of: $0) }).first { $0.lowercased() == "templates" }
    }

    static let known = ["YYYY-MM-DD", "DD-MM-YYYY", "YYYYMMDD", "DD.MM.YYYY", "YYYY.MM.DD", "YYYY/MM/DD"]

    static func infer(notes: [String]) -> BrainDailyConfig? {
        let probe = Date(timeIntervalSince1970: 1_700_000_000)
        var best: (config: BrainDailyConfig, count: Int)?
        let folders = Dictionary(grouping: notes) { BrainText.parent(of: $0) }
        for (folder, paths) in folders where paths.count >= 5 {
            for format in known {
                let shape = shapeRegex(for: MomentFormat.string(from: probe, format: format, locale: Locale(identifier: "en_US_POSIX")))
                let count = paths.filter { BrainText.stem(of: $0).range(of: shape, options: .regularExpression) != nil }.count
                if count * 2 >= paths.count, count >= 5, count > (best?.count ?? 0) {
                    best = (BrainDailyConfig(folder: folder, format: format), count)
                }
            }
        }
        return best?.config
    }

    private static func shapeRegex(for sample: String) -> String {
        "^" + sample.map { $0.isNumber ? "\\d" : NSRegularExpression.escapedPattern(for: String($0)) }.joined() + "$"
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func clean(_ folder: String) -> String {
        folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    private static func normalize(_ template: String) -> String {
        let trimmed = template.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return trimmed.lowercased().hasSuffix(".md") ? trimmed : trimmed + ".md"
    }

    public func path(for date: Date, locale: Locale = MomentFormat.defaultLocale, calendar: Calendar = .current) -> String {
        BrainText.join(folder, MomentFormat.string(from: date, format: format, locale: locale, calendar: calendar) + ".md")
    }
}

public enum BrainTemplate {
    public static func render(_ template: String, title: String, date: Date, locale: Locale = MomentFormat.defaultLocale, calendar: Calendar = .current) -> String {
        var out = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            out += rest[..<open.lowerBound]
            let inner = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            let name = inner.split(separator: ":", maxSplits: 1).first.map(String.init) ?? inner
            let format = inner.contains(":") ? String(inner[inner.index(after: inner.firstIndex(of: ":")!)...]) : nil
            switch name {
            case "title": out += title
            case "date": out += MomentFormat.string(from: date, format: format ?? "YYYY-MM-DD", locale: locale, calendar: calendar)
            case "time": out += MomentFormat.string(from: date, format: format ?? "HH:mm", locale: locale, calendar: calendar)
            default: out += rest[open.lowerBound..<close.upperBound]
            }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }
}
