import SwiftUI
import WispCore

enum BrainLinkScheme {
    static let scheme = "wisp-brain"

    static func note(_ link: BrainWikiLink, exists: Bool) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = exists ? "open" : "missing"
        components.queryItems = [URLQueryItem(name: "name", value: link.name), URLQueryItem(name: "heading", value: link.heading)]
        return components.url
    }

    static func tag(_ name: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "tag"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    enum Action {
        case note(BrainWikiLink, exists: Bool)
        case tag(String)
    }

    static func action(for url: URL) -> Action? {
        guard url.scheme == scheme, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String { items.first { $0.name == name }?.value ?? "" }
        switch url.host {
        case "open": return .note(BrainWikiLink(name: value("name"), heading: value("heading")), exists: true)
        case "missing": return .note(BrainWikiLink(name: value("name"), heading: value("heading")), exists: false)
        case "tag": return .tag(value("name"))
        default: return nil
        }
    }
}

@MainActor
struct BrainInlineStyle {
    var size: CGFloat = 13
    var bold = false
    var italic = false
    var strike = false
    var mono = false
    var highlight = false
    var color: Color = Theme.textPrimary

    var font: Font {
        var font = Font.system(size: mono ? size - 1 : size, weight: bold ? .bold : .regular, design: mono ? .monospaced : .default)
        if italic { font = font.italic() }
        return font
    }
}

@MainActor
enum BrainInlineText {
    static func attributed(_ inline: [BrainInline], style: BrainInlineStyle = BrainInlineStyle(), exists: (BrainWikiLink) -> Bool) -> AttributedString {
        var out = AttributedString()
        for piece in inline { out += run(piece, style: style, exists: exists) }
        return out
    }

    private static func styled(_ text: String, _ style: BrainInlineStyle) -> AttributedString {
        var piece = AttributedString(text)
        piece.font = style.font
        piece.foregroundColor = style.color
        if style.strike { piece.strikethroughStyle = .single }
        if style.mono { piece.backgroundColor = Theme.surfaceHi }
        if style.highlight { piece.backgroundColor = Theme.busy.opacity(0.35) }
        return piece
    }

    private static func run(_ piece: BrainInline, style: BrainInlineStyle, exists: (BrainWikiLink) -> Bool) -> AttributedString {
        switch piece {
        case .text(let text):
            return styled(text, style)
        case .code(let text):
            var code = style
            code.mono = true
            return styled(text, code)
        case .bold(let inner):
            var next = style
            next.bold = true
            return attributed(inner, style: next, exists: exists)
        case .italic(let inner):
            var next = style
            next.italic = true
            return attributed(inner, style: next, exists: exists)
        case .strike(let inner):
            var next = style
            next.strike = true
            return attributed(inner, style: next, exists: exists)
        case .highlight(let inner):
            var next = style
            next.highlight = true
            return attributed(inner, style: next, exists: exists)
        case .link(let label, let url):
            var next = style
            next.color = Theme.accent
            var text = attributed(label, style: next, exists: exists)
            text.link = URL(string: url)
            text.underlineStyle = .single
            return text
        case .wikilink(let link):
            let found = exists(link)
            var next = style
            next.color = found ? Theme.accent : Theme.textTertiary
            var text = styled(link.display, next)
            text.link = BrainLinkScheme.note(link, exists: found)
            if !found { text.underlineStyle = Text.LineStyle(pattern: .dot, color: Theme.textTertiary) }
            return text
        case .embed(let embed):
            let link = BrainWikiLink(name: embed.name, heading: embed.heading)
            var next = style
            next.color = Theme.accent
            var text = styled("⧉ " + embed.name, next)
            text.link = BrainLinkScheme.note(link, exists: exists(link))
            return text
        case .image(let alt, let url):
            var next = style
            next.color = Theme.accent
            var text = styled("▣ " + (alt.isEmpty ? url : alt), next)
            text.link = URL(string: url)
            return text
        case .tag(let name):
            var next = style
            next.color = Theme.accentTeal
            var text = styled("#" + name, next)
            text.link = BrainLinkScheme.tag(name)
            return text
        case .footnote(let label):
            var next = style
            next.size = style.size - 3
            next.color = Theme.accent
            var text = styled(label, next)
            text.baselineOffset = 5
            return text
        case .lineBreak:
            return AttributedString("\n")
        }
    }
}
