import Foundation

public struct BrainSyntaxSpan: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case heading(Int), bold, italic, strike, highlight, code, codeBlock, fence, wikilink, link, tag, quote, marker, comment, frontmatter
    }

    public var range: NSRange
    public var kind: Kind
}

public enum BrainSyntax {
    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = [.anchorsMatchLines]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let heading = regex(#"^(#{1,6})[ \t]+.*$"#)
    private static let quote = regex(#"^[ \t]*>.*$"#)
    private static let marker = regex(#"^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t])?"#)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = regex(#"(?<![\w*])(\*|_)(?=[^\s*_])(.+?)(?<=[^\s*_])\1(?![\w*])"#)
    private static let strike = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let highlight = regex(#"==(?=\S)(.+?)(?<=\S)=="#)
    private static let inlineCode = regex(#"(`+)(?!`)(.+?)(?<!`)\1(?!`)"#)
    private static let wikilink = regex(#"!?\[\[[^\[\]\n]*\]\]"#)
    private static let link = regex(#"\[[^\[\]\n]*\]\([^)\n]*\)"#)
    private static let tag = regex(#"(?<![\w&/#])#(?=[\w/-]*[A-Za-z\p{L}])[\w/-]+"#)
    private static let comment = regex(#"%%.*?%%"#, [.dotMatchesLineSeparators])

    public static func spans(in text: String) -> [BrainSyntaxSpan] {
        let ns = text as NSString
        var spans: [BrainSyntaxSpan] = []
        var codeRanges: [NSRange] = []
        var location = 0
        var fence: String?
        var inFront = text.hasPrefix("---")
        var firstLine = true
        while location < ns.length {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            let content = ns.substring(with: line).trimmingCharacters(in: .newlines)
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if inFront {
                spans.append(BrainSyntaxSpan(range: line, kind: .frontmatter))
                codeRanges.append(line)
                if !firstLine, trimmed == "---" || trimmed == "..." { inFront = false }
                if firstLine, trimmed != "---" {
                    inFront = false
                    spans.removeLast()
                    codeRanges.removeLast()
                }
            } else if let open = fence {
                spans.append(BrainSyntaxSpan(range: line, kind: .codeBlock))
                codeRanges.append(line)
                if trimmed.hasPrefix(open) {
                    spans.append(BrainSyntaxSpan(range: line, kind: .fence))
                    fence = nil
                }
            } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                spans.append(BrainSyntaxSpan(range: line, kind: .codeBlock))
                spans.append(BrainSyntaxSpan(range: line, kind: .fence))
                codeRanges.append(line)
            }
            firstLine = false
            location = NSMaxRange(line)
        }
        func outside(_ range: NSRange) -> Bool { !codeRanges.contains { NSIntersectionRange($0, range).length > 0 } }
        func run(_ expression: NSRegularExpression, _ kind: (NSTextCheckingResult) -> BrainSyntaxSpan.Kind, skipCode: Bool = true) {
            expression.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let match, !skipCode || outside(match.range) else { return }
                spans.append(BrainSyntaxSpan(range: match.range, kind: kind(match)))
            }
        }
        run(heading) { .heading($0.range(at: 1).length) }
        run(quote) { _ in .quote }
        run(marker) { _ in .marker }
        run(bold) { _ in .bold }
        run(italic) { _ in .italic }
        run(strike) { _ in .strike }
        run(highlight) { _ in .highlight }
        run(inlineCode) { _ in .code }
        run(wikilink) { _ in .wikilink }
        run(link) { _ in .link }
        run(tag) { _ in .tag }
        run(comment) { _ in .comment }
        return spans
    }
}

public enum BrainAsk {
    public static let limit = 24_000

    public static func context(path: String, title: String, text: String) -> String {
        let clipped = text.count > limit ? String(text.prefix(limit)) + "\n[…nota cortada em \(limit) caracteres; use brain_read para o resto]" : text
        return "O usuário está lendo a nota [[\(BrainText.withoutMarkdownSuffix(path))]] (\(title)) do brain. Conteúdo atual:\n\n<nota caminho=\"\(path)\">\n\(clipped)\n</nota>"
    }
}
