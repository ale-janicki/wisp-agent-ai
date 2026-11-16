import Foundation

public enum TelegramHTML {
    private static let replacements: [(pattern: String, template: String)] = [
        (#"<a\s+href\s*=\s*"([^"]*)"\s*>(.*?)</a>"#, "[$2]($1)"),
        (#"<pre(?:\s[^>]*)?>\s*(?:<code(?:\s[^>]*)?>)?(.*?)(?:</code>)?\s*</pre>"#, "```\n$1\n```"),
        (#"<code(?:\s[^>]*)?>(.*?)</code>"#, "`$1`"),
        (#"<(?:b|strong)>(.*?)</(?:b|strong)>"#, "**$1**"),
        (#"<(?:i|em)>(.*?)</(?:i|em)>"#, "*$1*"),
        (#"<(?:s|strike|del)>(.*?)</(?:s|strike|del)>"#, "~~$1~~"),
        (#"</?(?:u|ins|tg-spoiler|span|blockquote)(?:\s[^>]*)?>"#, ""),
    ]

    private static let entities: [(String, String)] = [
        ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&amp;", "&"),
    ]

    public static func markdown(_ html: String) -> String {
        var text = html
        for (pattern, template) in replacements {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        for (entity, character) in entities { text = text.replacingOccurrences(of: entity, with: character) }
        return text
    }
}
