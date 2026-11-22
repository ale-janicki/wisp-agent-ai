import Foundation

public enum DrawingLink: Equatable, Sendable {
    case note(target: String, heading: String?)
    case url(URL)

    public var noteReference: String? {
        guard case .note(let target, let heading) = self else { return nil }
        return heading.map { "\(target)#\($0)" } ?? target
    }

    public static func parse(_ link: String) -> DrawingLink? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let inner = wikilinkInner(trimmed) { return note(fromWikilink: inner) }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
            return .url(url)
        }
        return nil
    }

    public static func wikilinks(in text: String) -> [DrawingLink] {
        guard let regex = try? NSRegularExpression(pattern: "\\[\\[([^\\]\\n]+)\\]\\]") else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            note(fromWikilink: ns.substring(with: match.range(at: 1)))
        }
    }

    private static func wikilinkInner(_ text: String) -> String? {
        var body = Substring(text)
        if body.hasPrefix("!") { body = body.dropFirst() }
        guard body.hasPrefix("[["), body.hasSuffix("]]"), body.count > 4 else { return nil }
        return String(body.dropFirst(2).dropLast(2))
    }

    private static func note(fromWikilink inner: String) -> DrawingLink? {
        let beforeAlias = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? inner
        let parts = beforeAlias.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let target = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let heading = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
        guard !target.isEmpty || heading != nil else { return nil }
        return .note(target: target, heading: heading?.isEmpty == true ? nil : heading)
    }
}
