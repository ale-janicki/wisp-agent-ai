import Foundation

public struct BrainWikiLink: Sendable, Equatable {
    public var name: String
    public var heading: String
    public var alias: String?

    public var display: String {
        if let alias, !alias.isEmpty { return alias }
        if name.isEmpty { return heading }
        return heading.isEmpty ? name : name + " > " + heading
    }

    public init(name: String, heading: String = "", alias: String? = nil) {
        self.name = name
        self.heading = heading
        self.alias = alias
    }
}

public struct BrainEmbed: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case note, image, drawing, attachment }

    public var name: String
    public var heading: String
    public var option: String?
    public var kind: Kind

    public init(name: String, heading: String = "", option: String? = nil) {
        self.name = name
        self.heading = heading
        self.option = option
        self.kind = Self.kind(of: name)
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "bmp", "avif", "tif", "tiff"]

    public static func kind(of name: String) -> Kind {
        let lowered = name.lowercased()
        if lowered.hasSuffix(".excalidraw") || lowered.hasSuffix(".excalidraw.md") || lowered.hasSuffix(".canvas") { return .drawing }
        let ext = (lowered as NSString).pathExtension
        if imageExtensions.contains(ext) { return .image }
        if ext.isEmpty || ext == "md" { return .note }
        return BrainLinkScanner.attachmentExtensions.contains(ext) ? .attachment : .note
    }
}

public indirect enum BrainInline: Sendable, Equatable {
    case text(String)
    case code(String)
    case bold([BrainInline])
    case italic([BrainInline])
    case strike([BrainInline])
    case highlight([BrainInline])
    case link(label: [BrainInline], url: String)
    case wikilink(BrainWikiLink)
    case embed(BrainEmbed)
    case image(alt: String, url: String)
    case tag(String)
    case footnote(String)
    case lineBreak
}

public enum BrainTaskState: Sendable, Equatable {
    case open
    case done
}

public enum BrainAlignment: Sendable, Equatable {
    case leading, center, trailing
}

public struct BrainFootnote: Sendable, Equatable {
    public var label: String
    public var content: [BrainInline]
}

public struct BrainListItem: Sendable, Equatable {
    public var line: Int
    public var task: BrainTaskState?
    public var raw = ""
    public var blocks: [BrainBlockNode]
}

public struct BrainBlockNode: Sendable, Equatable, Identifiable {
    public var line: Int
    public var block: BrainBlock

    public var id: Int { line }
}

public indirect enum BrainBlock: Sendable, Equatable {
    case heading(level: Int, text: [BrainInline])
    case paragraph([BrainInline])
    case list(ordered: Bool, start: Int, items: [BrainListItem])
    case quote([BrainBlockNode])
    case callout(kind: String, title: [BrainInline], foldable: Bool, collapsed: Bool, body: [BrainBlockNode])
    case code(language: String, text: String)
    case table(header: [[BrainInline]], alignments: [BrainAlignment], rows: [[[BrainInline]]])
    case rule
    case embed(BrainEmbed)
    case footnotes([BrainFootnote])
}

public struct BrainHeading: Sendable, Equatable, Identifiable {
    public var level: Int
    public var text: String
    public var line: Int

    public var id: Int { line }
}

public struct BrainRenderModel: Sendable, Equatable {
    public var nodes: [BrainBlockNode]
    public var headings: [BrainHeading]
    public var tags: [String]
    public var frontmatterLines: Int

    public static let empty = BrainRenderModel(nodes: [], headings: [], tags: [], frontmatterLines: 0)

    public func headingLine(matching heading: String) -> Int? {
        let wanted = BrainText.fold(heading.split(separator: "#").last.map(String.init) ?? heading).trimmingCharacters(in: .whitespaces)
        return headings.first { BrainText.fold($0.text).trimmingCharacters(in: .whitespaces) == wanted }?.line
    }
}

public enum BrainSections {
    public static func extract(_ text: String, heading: String) -> String? {
        let wanted = BrainText.fold(heading.split(separator: "#").last.map(String.init) ?? heading).trimmingCharacters(in: .whitespaces)
        let lines = BrainText.lines(text).map { Substring(BrainText.withoutCarriageReturn($0)) }
        var start: Int?
        var level = 0
        var fence: Substring?
        for (i, line) in lines.enumerated() {
            let lead = line.drop { $0 == " " || $0 == "\t" }
            if fence == nil, lead.hasPrefix("```") || lead.hasPrefix("~~~") {
                fence = lead.prefix(3)
                continue
            }
            if let open = fence {
                if lead.hasPrefix(open) { fence = nil }
                continue
            }
            guard let parsed = headingParts(line) else { continue }
            if start == nil {
                if BrainText.fold(parsed.text) == wanted {
                    start = i
                    level = parsed.level
                }
            } else if parsed.level <= level {
                return lines[start!..<i].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let start else { return nil }
        return lines[start...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func headingParts(_ line: Substring) -> (level: Int, text: String)? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 7 {
            level += 1
            index = line.index(after: index)
        }
        guard (1...6).contains(level), index < line.endIndex, line[index] == " " || line[index] == "\t" else { return nil }
        var text = line[index...].trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (level, text)
    }
}
