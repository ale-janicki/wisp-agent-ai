import Foundation

public enum TelegramHTML {
    private static let replacements: [(pattern: String, template: String)] = [
        (#"<br\s*/?>"#, "\n"),
        (#"<a\s+href\s*=\s*"([^"]*)"\s*>(.*?)</a>"#, "[$2]($1)"),
        (#"<pre(?:\s[^>]*)?>\s*(?:<code(?:\s[^>]*)?>)?(.*?)(?:</code>)?\s*</pre>"#, "```\n$1\n```"),
        (#"<code(?:\s[^>]*)?>(.*?)</code>"#, "`$1`"),
        (#"<(?:b|strong)>(.*?)</(?:b|strong)>"#, "**$1**"),
        (#"<(?:i|em)>(.*?)</(?:i|em)>"#, "*$1*"),
        (#"<(?:s|strike|del)>(.*?)</(?:s|strike|del)>"#, "~~$1~~"),
        (#"</?(?:u|ins|tg-spoiler|span)(?:\s[^>]*)?>"#, ""),
    ]

    private static let blockquote = #"<blockquote(?:\s[^>]*)?>(.*?)</blockquote>"#

    private static let entities: [(String, String)] = [
        ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&amp;", "&"),
    ]

    private static let markdownCode = try? NSRegularExpression(pattern: #"```[\s\S]*?```|`[^`\n]+`"#)

    public static func markdown(_ html: String) -> String {
        guard html.contains("<") || html.contains("&") else { return html }
        guard let markdownCode else { return convert(html) }
        let nsText = html as NSString
        var out = ""
        var cursor = 0
        for match in markdownCode.matches(in: html, range: NSRange(location: 0, length: nsText.length)) {
            out += convert(nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            out += nsText.substring(with: match.range)
            cursor = match.range.location + match.range.length
        }
        return out + convert(nsText.substring(from: cursor))
    }

    private static func convert(_ html: String) -> String {
        var text = html
        if let regex = try? NSRegularExpression(pattern: blockquote, options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let whole = Range(match.range, in: text), let inner = Range(match.range(at: 1), in: text) else { continue }
                let quoted = text[inner].trimmingCharacters(in: .whitespacesAndNewlines)
                    .split(separator: "\n", omittingEmptySubsequences: false).map { "> \($0)" }.joined(separator: "\n")
                text.replaceSubrange(whole, with: quoted)
            }
        }
        for (pattern, template) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        for (entity, character) in entities { text = text.replacingOccurrences(of: entity, with: character) }
        return text
    }
}
