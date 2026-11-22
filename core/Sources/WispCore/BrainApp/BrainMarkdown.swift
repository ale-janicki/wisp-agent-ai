import Foundation

public enum BrainMarkdown {
    public static func parse(_ text: String) -> BrainRenderModel {
        let document = BrainDocument(text)
        let skipped = document.frontmatterLineCount
        let all = BrainText.lines(text)
        var lines: [BrainLine] = []
        lines.reserveCapacity(all.count)
        for (number, raw) in all.enumerated() where number >= skipped {
            lines.append(BrainLine(number: number, text: expandTabs(Substring(BrainText.withoutCarriageReturn(raw)))))
        }
        var parser = BrainBlockParser()
        var nodes = parser.blocks(lines)
        if !parser.footnotes.isEmpty, let last = lines.last {
            nodes.append(BrainBlockNode(line: last.number + 1, block: .footnotes(parser.footnotes)))
        }
        let headings = nodes.compactMap { node -> BrainHeading? in
            guard case .heading(let level, let inline) = node.block else { return nil }
            return BrainHeading(level: level, text: BrainInlineParser.plain(inline), line: node.line)
        }
        return BrainRenderModel(nodes: nodes, headings: headings, tags: parser.tags.sorted(), frontmatterLines: skipped)
    }

    static func expandTabs(_ line: Substring) -> String {
        guard line.first == "\t" || line.contains("\t") else { return String(line) }
        var out = ""
        var leading = true
        for character in line {
            if character == "\t", leading {
                out += "    "
            } else {
                if character != " " { leading = false }
                out.append(character)
            }
        }
        return out
    }
}

struct BrainLine {
    var number: Int
    var text: String

    var isBlank: Bool { text.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" } }

    var indent: Int { text.prefix { $0 == " " }.count }
}

struct BrainBlockParser {
    var tags = Set<String>()
    var footnotes: [BrainFootnote] = []

    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern) }

    private static let fence = regex(#"^ {0,3}(`{3,}|~{3,})[ \t]*([^`\s]*)[^`]*$"#)
    private static let rule = regex(#"^ {0,3}([-*_])(?:[ \t]*\1){2,}[ \t]*$"#)
    private static let listItem = regex(#"^( *)([-*+]|\d{1,9}[.)])( +|$)(.*)$"#)
    private static let callout = regex(#"^\[!([A-Za-z0-9_-]+)\]([+-])?[ \t]*(.*)$"#)
    private static let footnoteDefinition = regex(#"^\[\^([^\]\s]+)\]:[ \t]*(.*)$"#)
    private static let delimiterRow = regex(#"^[ \t]*\|?[ \t]*:?-{1,}:?[ \t]*(?:\|[ \t]*:?-{1,}:?[ \t]*)*\|?[ \t]*$"#)
    private static let embedOnly = regex(#"^[ \t]*!\[\[[^\[\]\n]+\]\][ \t]*$"#)
    private static let taskMarker = regex(#"^\[([ xX])\](?:[ \t]+|$)(.*)$"#)

    private func match(_ expression: NSRegularExpression, _ text: String) -> NSTextCheckingResult? {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    private func group(_ result: NSTextCheckingResult, _ index: Int, in text: String) -> String {
        Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
    }

    private func startsBlock(_ line: BrainLine) -> Bool {
        let text = line.text
        guard let first = text.drop(while: { $0 == " " }).first else { return false }
        switch first {
        case "`", "~": if match(Self.fence, text) != nil { return true }
        case "#": if BrainSections.headingParts(Substring(text.drop { $0 == " " })) != nil { return true }
        case ">": return true
        case "-", "*", "_": if match(Self.rule, text) != nil { return true }
        default: break
        }
        if "-*+0123456789".contains(first), match(Self.listItem, text) != nil { return true }
        return match(Self.embedOnly, text) != nil
    }

    mutating func blocks(_ lines: [BrainLine]) -> [BrainBlockNode] {
        var nodes: [BrainBlockNode] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.isBlank {
                i += 1
                continue
            }
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("%%") {
                if trimmed.count > 2, trimmed.hasSuffix("%%") {
                    i += 1
                } else {
                    i += 1
                    while i < lines.count, !lines[i].text.contains("%%") { i += 1 }
                    i += 1
                }
                continue
            }
            if let result = match(Self.fence, line.text) {
                let marker = group(result, 1, in: line.text)
                let language = group(result, 2, in: line.text)
                var body: [String] = []
                var j = i + 1
                let indent = line.indent
                while j < lines.count {
                    let candidate = lines[j].text.drop { $0 == " " }
                    if candidate.hasPrefix(marker), candidate.allSatisfy({ $0 == marker.first! || $0 == " " }) { break }
                    body.append(String(lines[j].text.dropFirst(min(indent, lines[j].indent))))
                    j += 1
                }
                nodes.append(BrainBlockNode(line: line.number, block: .code(language: language, text: body.joined(separator: "\n"))))
                i = min(j + 1, lines.count)
                continue
            }
            if let heading = BrainSections.headingParts(Substring(line.text.drop { $0 == " " })), line.indent < 4 {
                nodes.append(BrainBlockNode(line: line.number, block: .heading(level: heading.level, text: inline(heading.text))))
                i += 1
                continue
            }
            if match(Self.rule, line.text) != nil {
                nodes.append(BrainBlockNode(line: line.number, block: .rule))
                i += 1
                continue
            }
            if let result = match(Self.footnoteDefinition, line.text) {
                var content = [group(result, 2, in: line.text)]
                var j = i + 1
                while j < lines.count, lines[j].indent >= 2, !lines[j].isBlank {
                    content.append(lines[j].text.trimmingCharacters(in: .whitespaces))
                    j += 1
                }
                footnotes.append(BrainFootnote(label: group(result, 1, in: line.text), content: inline(content.joined(separator: " "))))
                i = j
                continue
            }
            if match(Self.embedOnly, line.text) != nil, let embed = BrainInlineParser.parse(trimmed, tags: &tags).first, case .embed(let value) = embed {
                nodes.append(BrainBlockNode(line: line.number, block: .embed(value)))
                i += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                let (node, next) = quote(lines, from: i)
                nodes.append(node)
                i = next
                continue
            }
            if i + 1 < lines.count, trimmed.contains("|"), let (node, next) = table(lines, from: i) {
                nodes.append(node)
                i = next
                continue
            }
            if match(Self.listItem, line.text) != nil, line.indent < 4 {
                let (node, next) = list(lines, from: i)
                nodes.append(node)
                i = next
                continue
            }
            var j = i + 1
            while j < lines.count, !lines[j].isBlank, !startsBlock(lines[j]) { j += 1 }
            nodes.append(BrainBlockNode(line: line.number, block: .paragraph(paragraph(lines[i..<j]))))
            i = j
        }
        return nodes
    }

    private mutating func inline(_ text: String) -> [BrainInline] {
        BrainInlineParser.parse(text, tags: &tags)
    }

    private mutating func paragraph(_ lines: ArraySlice<BrainLine>) -> [BrainInline] {
        var out: [BrainInline] = []
        for (offset, line) in lines.enumerated() {
            if offset > 0 { out.append(.lineBreak) }
            out += inline(line.text.trimmingCharacters(in: .whitespaces))
        }
        return out
    }

    private mutating func quote(_ lines: [BrainLine], from start: Int) -> (BrainBlockNode, Int) {
        var inner: [BrainLine] = []
        var j = start
        while j < lines.count {
            let text = lines[j].text.drop { $0 == " " }
            guard text.hasPrefix(">") else { break }
            var rest = text.dropFirst()
            if rest.hasPrefix(" ") { rest = rest.dropFirst() }
            inner.append(BrainLine(number: lines[j].number, text: String(rest)))
            j += 1
        }
        if let first = inner.first, let result = match(Self.callout, first.text) {
            let kind = group(result, 1, in: first.text).lowercased()
            let fold = group(result, 2, in: first.text)
            var title = group(result, 3, in: first.text)
            if title.isEmpty { title = kind.prefix(1).uppercased() + kind.dropFirst() }
            let body = blocks(Array(inner.dropFirst()))
            return (BrainBlockNode(line: lines[start].number, block: .callout(kind: kind, title: inline(title), foldable: !fold.isEmpty, collapsed: fold == "-", body: body)), j)
        }
        return (BrainBlockNode(line: lines[start].number, block: .quote(blocks(inner))), j)
    }

    private func cells(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inCode = false
        var previous: Character?
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        for character in text {
            if character == "`" { inCode.toggle() }
            if character == "|", !inCode, previous != "\\" {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
            previous = character
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty || !text.hasSuffix("|") { out.append(last) }
        return out
    }

    private mutating func table(_ lines: [BrainLine], from start: Int) -> (BrainBlockNode, Int)? {
        let delimiter = lines[start + 1].text
        guard delimiter.contains("-"), match(Self.delimiterRow, delimiter) != nil else { return nil }
        let header = cells(lines[start].text)
        let marks = cells(delimiter)
        guard header.count == marks.count, header.count > 0, lines[start].text.contains("|") || marks.count > 1 else { return nil }
        let alignments = marks.map { mark -> BrainAlignment in
            let left = mark.hasPrefix(":"), right = mark.hasSuffix(":")
            return left && right ? .center : (right ? .trailing : .leading)
        }
        var rows: [[[BrainInline]]] = []
        var j = start + 2
        while j < lines.count, !lines[j].isBlank, lines[j].text.contains("|") {
            var row = cells(lines[j].text)
            if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
            rows.append(row.prefix(header.count).map { inline($0) })
            j += 1
        }
        return (BrainBlockNode(line: lines[start].number, block: .table(header: header.map { inline($0) }, alignments: alignments, rows: rows)), j)
    }

    private mutating func list(_ lines: [BrainLine], from start: Int) -> (BrainBlockNode, Int) {
        let first = match(Self.listItem, lines[start].text)!
        let base = group(first, 1, in: lines[start].text).count
        let ordered = group(first, 2, in: lines[start].text).first!.isNumber
        let startNumber = ordered ? Int(group(first, 2, in: lines[start].text).dropLast()) ?? 1 : 1
        var items: [BrainListItem] = []
        var i = start
        while i < lines.count {
            guard let marker = match(Self.listItem, lines[i].text) else { break }
            let indent = group(marker, 1, in: lines[i].text).count
            if indent < base || (indent >= base + 4 && !items.isEmpty) { break }
            let symbol = group(marker, 2, in: lines[i].text)
            if symbol.first!.isNumber != ordered { break }
            let spaces = group(marker, 3, in: lines[i].text).count
            let content = indent + symbol.count + (spaces == 0 || spaces > 4 ? 1 : spaces)
            var itemLines = [BrainLine(number: lines[i].number, text: group(marker, 4, in: lines[i].text))]
            var j = i + 1
            while j < lines.count {
                let candidate = lines[j]
                if candidate.isBlank {
                    var k = j
                    while k < lines.count, lines[k].isBlank { k += 1 }
                    guard k < lines.count, lines[k].indent >= content else { break }
                    for blank in j..<k { itemLines.append(BrainLine(number: lines[blank].number, text: "")) }
                    j = k
                    continue
                }
                if candidate.indent >= content {
                    itemLines.append(BrainLine(number: candidate.number, text: String(candidate.text.dropFirst(content))))
                    j += 1
                    continue
                }
                if match(Self.listItem, candidate.text) != nil || startsBlock(candidate) { break }
                if let previous = itemLines.last, !previous.isBlank {
                    itemLines.append(BrainLine(number: candidate.number, text: candidate.text.trimmingCharacters(in: .whitespaces)))
                    j += 1
                    continue
                }
                break
            }
            var task: BrainTaskState?
            if let found = match(Self.taskMarker, itemLines[0].text) {
                task = group(found, 1, in: itemLines[0].text) == " " ? .open : .done
                itemLines[0].text = group(found, 2, in: itemLines[0].text)
            }
            items.append(BrainListItem(line: lines[i].number, task: task, raw: lines[i].text, blocks: blocks(itemLines)))
            i = j
        }
        return (BrainBlockNode(line: lines[start].number, block: .list(ordered: ordered, start: startNumber, items: items)), i)
    }
}

enum BrainInlineParser {
    static func parse(_ text: String, tags: inout Set<String>) -> [BrainInline] {
        var parser = Scanner(chars: Array(text))
        let result = parser.run(0, parser.chars.count)
        tags.formUnion(parser.tags)
        return result
    }

    static func plain(_ inline: [BrainInline]) -> String {
        inline.map { piece -> String in
            switch piece {
            case .text(let value), .code(let value): value
            case .bold(let inner), .italic(let inner), .strike(let inner), .highlight(let inner): plain(inner)
            case .link(let label, _): plain(label)
            case .wikilink(let link): link.display
            case .embed(let embed): embed.name
            case .image(let alt, _): alt
            case .tag(let name): "#" + name
            case .footnote(let label): "[" + label + "]"
            case .lineBreak: " "
            }
        }.joined()
    }

    static func wikiParts(_ inner: String) -> (name: String, heading: String, alias: String?) {
        var target = inner
        var alias: String?
        if let pipe = inner.firstIndex(of: "|") {
            target = String(inner[..<pipe])
            alias = String(inner[inner.index(after: pipe)...])
        }
        if target.hasSuffix("\\") { target.removeLast() }
        var name = target
        var heading = ""
        if let hash = target.firstIndex(of: "#") {
            name = String(target[..<hash])
            heading = String(target[target.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
            if heading.hasPrefix("^") { heading = "" }
        }
        return (name.trimmingCharacters(in: .whitespaces), heading, alias)
    }

    struct Scanner {
        var chars: [Character]
        var tags = Set<String>()

        private func isPunctuation(_ c: Character) -> Bool { c.isASCII && (c.isPunctuation || c.isSymbol) }

        private func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }

        private func find(_ token: [Character], from start: Int, to end: Int) -> Int? {
            var i = start
            while i + token.count <= end {
                if chars[i] == "\\" {
                    i += 2
                    continue
                }
                if chars[i] == "`" {
                    var run = i
                    while run < end, chars[run] == "`" { run += 1 }
                    if let close = findCodeClose(run - i, from: run, to: end) {
                        i = close
                        continue
                    }
                    i = run
                    continue
                }
                if Array(chars[i..<(i + token.count)]) == token { return i }
                i += 1
            }
            return nil
        }

        private func findCodeClose(_ length: Int, from start: Int, to end: Int) -> Int? {
            var i = start
            while i < end {
                guard chars[i] == "`" else {
                    i += 1
                    continue
                }
                var run = i
                while run < end, chars[run] == "`" { run += 1 }
                if run - i == length { return run }
                i = run
            }
            return nil
        }

        private func string(_ from: Int, _ to: Int) -> String { String(chars[from..<to]) }

        mutating func run(_ start: Int, _ end: Int) -> [BrainInline] {
            var out: [BrainInline] = []
            var buffer = ""
            func flush() {
                if !buffer.isEmpty { out.append(.text(buffer)) }
                buffer = ""
            }
            var i = start
            while i < end {
                let c = chars[i]
                if c == "\\", i + 1 < end, isPunctuation(chars[i + 1]) {
                    buffer.append(chars[i + 1])
                    i += 2
                    continue
                }
                if c == "`" {
                    var run = i
                    while run < end, chars[run] == "`" { run += 1 }
                    if let close = findCodeClose(run - i, from: run, to: end) {
                        flush()
                        var code = string(run, close - (run - i))
                        if code.hasPrefix(" "), code.hasSuffix(" "), code.count > 2 { code = String(code.dropFirst().dropLast()) }
                        out.append(.code(code))
                        i = close
                    } else {
                        buffer += string(i, run)
                        i = run
                    }
                    continue
                }
                if c == "!", i + 2 < end, chars[i + 1] == "[", chars[i + 2] == "[", let close = find(["]", "]"], from: i + 3, to: end) {
                    flush()
                    let parts = Self.wiki(string(i + 3, close))
                    out.append(.embed(BrainEmbed(name: parts.name, heading: parts.heading, option: parts.alias)))
                    i = close + 2
                    continue
                }
                if c == "!", i + 1 < end, chars[i + 1] == "[", let (alt, url, next) = markdownLink(i + 1, end) {
                    flush()
                    out.append(.image(alt: alt, url: url))
                    i = next
                    continue
                }
                if c == "[", i + 1 < end, chars[i + 1] == "[", let close = find(["]", "]"], from: i + 2, to: end), !string(i + 2, close).contains("[") {
                    flush()
                    let parts = Self.wiki(string(i + 2, close))
                    out.append(.wikilink(BrainWikiLink(name: parts.name, heading: parts.heading, alias: parts.alias)))
                    i = close + 2
                    continue
                }
                if c == "[", i + 2 < end, chars[i + 1] == "^", let close = find(["]"], from: i + 2, to: end), close > i + 2,
                   !string(i + 2, close).contains(" ") {
                    flush()
                    out.append(.footnote(string(i + 2, close)))
                    i = close + 1
                    continue
                }
                if c == "[", let (label, url, next) = markdownLink(i, end) {
                    flush()
                    out.append(.link(label: run(i + 1, i + 1 + label.count), url: url))
                    i = next
                    continue
                }
                if let (pieces, next) = emphasis(at: i, end: end) {
                    flush()
                    out += pieces
                    i = next
                    continue
                }
                if c == "#", i == start || chars[i - 1] == " " || chars[i - 1] == "(" {
                    var j = i + 1
                    var hasLetter = false
                    while j < end, isWord(chars[j]) || chars[j] == "_" || chars[j] == "-" || chars[j] == "/" {
                        if chars[j].isLetter { hasLetter = true }
                        j += 1
                    }
                    if hasLetter, j > i + 1 {
                        flush()
                        let name = string(i + 1, j)
                        tags.insert(BrainText.fold(name))
                        out.append(.tag(name))
                        i = j
                        continue
                    }
                }
                if c == "h", i == start || !isWord(chars[i - 1]), let (url, next) = bareURL(i, end) {
                    flush()
                    out.append(.link(label: [.text(url)], url: url))
                    i = next
                    continue
                }
                if c == "<", string(i, min(end, i + 6)).lowercased().hasPrefix("<br"), let close = find([">"], from: i, to: end), close - i <= 5 {
                    flush()
                    out.append(.lineBreak)
                    i = close + 1
                    continue
                }
                buffer.append(c)
                i += 1
            }
            flush()
            return out
        }

        static func wiki(_ inner: String) -> (name: String, heading: String, alias: String?) {
            BrainInlineParser.wikiParts(inner)
        }

        private func bareURL(_ i: Int, _ end: Int) -> (String, Int)? {
            let head = string(i, min(end, i + 8))
            guard head.hasPrefix("http://") || head.hasPrefix("https://") else { return nil }
            var j = i
            while j < end, chars[j] != " ", chars[j] != "<", chars[j] != ">" { j += 1 }
            while j > i, ".,;:!?)'\"".contains(chars[j - 1]) { j -= 1 }
            return j - i > 8 ? (string(i, j), j) : nil
        }

        private func markdownLink(_ open: Int, _ end: Int) -> (label: String, url: String, next: Int)? {
            var depth = 0
            var j = open
            var close: Int?
            while j < end {
                if chars[j] == "\\" {
                    j += 2
                    continue
                }
                if chars[j] == "[" { depth += 1 }
                if chars[j] == "]" {
                    depth -= 1
                    if depth == 0 {
                        close = j
                        break
                    }
                }
                j += 1
            }
            guard let close, close + 1 < end, chars[close + 1] == "(" else { return nil }
            var parens = 0
            var k = close + 1
            var stop: Int?
            while k < end {
                if chars[k] == "(" { parens += 1 }
                if chars[k] == ")" {
                    parens -= 1
                    if parens == 0 {
                        stop = k
                        break
                    }
                }
                k += 1
            }
            guard let stop else { return nil }
            var url = string(close + 2, stop).trimmingCharacters(in: .whitespaces)
            if url.hasPrefix("<"), let closing = url.firstIndex(of: ">") {
                url = String(url[url.index(after: url.startIndex)..<closing])
            } else if let space = url.firstIndex(of: " ") {
                url = String(url[..<space])
            }
            return (string(open + 1, close), url, stop + 1)
        }

        private func closingRun(_ c: Character, size: Int, from start: Int, to end: Int) -> Int? {
            var j = start
            while j < end {
                if chars[j] == "\\" {
                    j += 2
                    continue
                }
                if chars[j] == "`" {
                    var run = j
                    while run < end, chars[run] == "`" { run += 1 }
                    j = findCodeClose(run - j, from: run, to: end) ?? run
                    continue
                }
                if chars[j] == c {
                    var run = j
                    while run < end, chars[run] == c { run += 1 }
                    if run - j == size { return j }
                    j = run
                    continue
                }
                j += 1
            }
            return nil
        }

        private mutating func emphasis(at i: Int, end: Int) -> ([BrainInline], Int)? {
            let c = chars[i]
            guard "*_=~".contains(c) else { return nil }
            var extent = i
            while extent < end, chars[extent] == c { extent += 1 }
            let size: Int
            if c == "=" || c == "~" {
                guard extent - i == 2 else { return nil }
                size = 2
            } else {
                size = min(extent - i, 3)
            }
            if c == "_", i > 0, isWord(chars[i - 1]) { return nil }
            guard i + size < end, chars[i + size] != " " else { return nil }
            var from = i + size
            while from < end, let close = closingRun(c, size: size, from: from, to: end) {
                let after = close + size
                let intraword = c == "_" && after < end && isWord(chars[after])
                if close > i + size, chars[close - 1] != " ", !intraword {
                    let inner = run(i + size, close)
                    let piece: BrainInline
                    switch (c, size) {
                    case ("=", _): piece = .highlight(inner)
                    case ("~", _): piece = .strike(inner)
                    case (_, 1): piece = .italic(inner)
                    case (_, 2): piece = .bold(inner)
                    default: piece = .bold([.italic(inner)])
                    }
                    return ([piece], after)
                }
                from = close + size
            }
            return nil
        }
    }
}
