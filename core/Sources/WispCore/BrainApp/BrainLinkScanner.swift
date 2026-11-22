import Foundation

public struct BrainLinkOccurrence: Sendable, Equatable {
    public var start: Int
    public var end: Int
    public var nameRange: Range<Int>
    public var name: String
    public var heading: String
    public var alias: String?
    public var isEmbed: Bool
    public var line: Int

    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }

    public var isAttachment: Bool { BrainLinkScanner.attachmentExtensions.contains(fileExtension) }
}

public enum BrainLinkScanner {
    public static let attachmentExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "pdf", "mp3", "mp4", "mov", "wav", "m4a", "webm", "excalidraw", "canvas", "base",
    ]

    private static let newline = UInt8(ascii: "\n"), space = UInt8(ascii: " "), tab = UInt8(ascii: "\t")
    private static let backtick = UInt8(ascii: "`"), tilde = UInt8(ascii: "~"), bang = UInt8(ascii: "!")
    private static let open = UInt8(ascii: "["), close = UInt8(ascii: "]")
    private static let pipe = UInt8(ascii: "|"), hash = UInt8(ascii: "#"), backslash = UInt8(ascii: "\\")

    public static func frontmatterLength(in bytes: [UInt8]) -> Int {
        guard bytes.starts(with: [0x2D, 0x2D, 0x2D]) else { return 0 }
        var lineStart = 0
        var first = true
        while lineStart < bytes.count {
            var end = lineStart
            while end < bytes.count && bytes[end] != newline { end += 1 }
            let line = BrainText.trimmed(bytes[lineStart..<end])
            let isFence = line.elementsEqual([0x2D, 0x2D, 0x2D])
            if first {
                if !isFence { return 0 }
                first = false
            } else if isFence || line.elementsEqual([0x2E, 0x2E, 0x2E]) {
                return min(end + 1, bytes.count)
            }
            lineStart = end + 1
        }
        return 0
    }

    public static func scan(_ text: String, includeFrontmatter: Bool = false) -> [BrainLinkOccurrence] {
        scan(Array(text.utf8), includeFrontmatter: includeFrontmatter)
    }

    public static func scan(_ bytes: [UInt8], includeFrontmatter: Bool = false) -> [BrainLinkOccurrence] {
        var found: [BrainLinkOccurrence] = []
        let skipped = includeFrontmatter ? 0 : frontmatterLength(in: bytes)
        var lineNumber = 0
        var fence: (mark: UInt8, length: Int)?
        var start = 0
        let count = bytes.count
        while start < count {
            var end = start
            while end < count && bytes[end] != newline { end += 1 }
            var first = start
            while first < end && first - start < 4 && (bytes[first] == space || bytes[first] == tab) { first += 1 }
            var isFenceLine = false
            if first < end, bytes[first] == backtick || bytes[first] == tilde {
                let mark = bytes[first]
                var run = first
                while run < end && bytes[run] == mark { run += 1 }
                if run - first >= 3 {
                    isFenceLine = true
                    if let current = fence {
                        if current.mark == mark && run - first >= current.length { fence = nil }
                    } else {
                        fence = (mark, run - first)
                    }
                }
            }
            if !isFenceLine && fence == nil && start >= skipped {
                scanLine(bytes, from: start, to: end, line: lineNumber, into: &found)
            }
            start = end + 1
            lineNumber += 1
        }
        return found
    }

    private static func scanLine(_ bytes: [UInt8], from start: Int, to end: Int, line: Int, into found: inout [BrainLinkOccurrence]) {
        var i = start
        while i < end {
            let byte = bytes[i]
            if byte == backtick {
                var run = i
                while run < end && bytes[run] == backtick { run += 1 }
                i = closingBackticks(bytes, length: run - i, from: run, to: end) ?? run
                continue
            }
            let embed = byte == bang && i + 2 < end && bytes[i + 1] == open && bytes[i + 2] == open
            if embed || (byte == open && i + 1 < end && bytes[i + 1] == open) {
                let inner = embed ? i + 3 : i + 2
                if let occurrence = parse(bytes, tokenStart: i, inner: inner, end: end, embed: embed, line: line) {
                    found.append(occurrence)
                    i = occurrence.end
                    continue
                }
            }
            i += 1
        }
    }

    private static func closingBackticks(_ bytes: [UInt8], length: Int, from start: Int, to end: Int) -> Int? {
        var i = start
        while i < end {
            guard bytes[i] == backtick else {
                i += 1
                continue
            }
            var run = i
            while run < end && bytes[run] == backtick { run += 1 }
            if run - i == length { return run }
            i = run
        }
        return nil
    }

    private static func parse(_ bytes: [UInt8], tokenStart: Int, inner: Int, end: Int, embed: Bool, line: Int) -> BrainLinkOccurrence? {
        var j = inner
        var pipeAt: Int?
        while j < end {
            let byte = bytes[j]
            if byte == open { return nil }
            if byte == close {
                guard j + 1 < end, bytes[j + 1] == close else { return nil }
                break
            }
            if byte == pipe, pipeAt == nil { pipeAt = j }
            j += 1
        }
        guard j + 1 < end else { return nil }
        let nameEnd = pipeAt ?? j
        var targetEnd = nameEnd
        var headingStart: Int?
        for k in inner..<nameEnd where bytes[k] == hash {
            targetEnd = k
            headingStart = k + 1
            break
        }
        var trailing = targetEnd
        if trailing > inner, bytes[trailing - 1] == backslash, pipeAt != nil, headingStart == nil { trailing -= 1 }
        var lower = inner, upper = trailing
        while lower < upper, bytes[lower] == space || bytes[lower] == tab { lower += 1 }
        while upper > lower, bytes[upper - 1] == space || bytes[upper - 1] == tab { upper -= 1 }
        let name = String(decoding: bytes[lower..<upper], as: UTF8.self)
        var heading = headingStart.map { String(decoding: BrainText.trimmed(bytes[$0..<nameEnd]), as: UTF8.self) } ?? ""
        if heading.hasPrefix("^") { heading = "" }
        let alias = pipeAt.map { String(decoding: bytes[($0 + 1)..<j], as: UTF8.self) }
        if name.isEmpty && heading.isEmpty { return nil }
        return BrainLinkOccurrence(
            start: tokenStart, end: j + 2, nameRange: lower..<upper, name: name, heading: heading, alias: alias, isEmbed: embed, line: line)
    }
}
