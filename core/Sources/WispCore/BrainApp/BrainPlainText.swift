import Foundation

/// Turns a line of markdown into the plain text a side-panel preview shows.
public enum BrainPlainText {
    public static func preview(_ markdown: String) -> String {
        var text = markdown.trimmingCharacters(in: .whitespaces)
        text = text.replacingOccurrences(of: #"^(?:[-*+]\s+|>+\s*|#{1,6}\s+)+"#, with: "", options: .regularExpression)
        text = wikilinksShown(text)
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "`", with: "")
        text = text.replacingOccurrences(of: #"\*\*|__"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?<![\w*])[*_]|[*_](?![\w*])"#, with: "", options: .regularExpression)
        if text.contains("|") {
            text = text.split(separator: "|", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { cell in cell.contains { $0 != "-" && $0 != ":" && !$0.isWhitespace } }
                .joined(separator: " · ")
        }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func wikilinksShown(_ value: String) -> String {
        var text = value
        while let open = text.range(of: "[["), let close = text.range(of: "]]", range: open.upperBound..<text.endIndex) {
            let inner = text[open.upperBound..<close.lowerBound]
            let shown = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? ""
            text.replaceSubrange(open.lowerBound..<close.upperBound, with: shown)
        }
        return text
    }
}
