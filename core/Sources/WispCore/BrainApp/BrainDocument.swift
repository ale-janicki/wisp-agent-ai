import Foundation

public struct BrainProperty: Sendable, Equatable, Identifiable {
    public enum Value: Sendable, Equatable {
        case text(String)
        case list([String])
        case complex(String)
    }

    public var key: String
    public var value: Value

    public var id: String { key }

    public init(key: String, value: Value) {
        self.key = key
        self.value = value
    }
}

public struct BrainDocument: Sendable, Equatable {
    private var opening = "---"
    private var closing = "---"
    private var closingEnd = "\n"
    private var front: [String]?
    public private(set) var body: String

    public init(_ text: String) {
        let lines = BrainText.lines(text)
        guard lines.count > 1, Self.isFence(lines[0], opening: true),
              let end = lines.indices.dropFirst().first(where: { Self.isFence(lines[$0], opening: false) })
        else {
            body = text
            return
        }
        opening = String(lines[0])
        closing = String(lines[end])
        front = Array(lines[1..<end])
        closingEnd = end == lines.count - 1 ? "" : "\n"
        body = end == lines.count - 1 ? "" : lines[(end + 1)...].joined(separator: "\n")
    }

    private static func isFence(_ line: String, opening: Bool) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "---" || (!opening && trimmed == "...")
    }

    public var hasFrontmatter: Bool { front != nil }

    public var text: String {
        guard let front else { return body }
        return opening + "\n" + front.joined(separator: "\n") + (front.isEmpty ? "" : "\n") + closing + closingEnd + body
    }

    public var frontmatterLineCount: Int {
        guard let front else { return 0 }
        return front.count + 2
    }

    public mutating func setBody(_ value: String) {
        body = value
    }

    private struct Entry {
        var key: String
        var range: Range<Int>
        var value: BrainProperty.Value
        var inline: Bool
    }

    private func entries() -> [Entry] {
        guard let front else { return [] }
        var found: [Entry] = []
        var i = 0
        while i < front.count {
            let line = front[i]
            guard let first = line.first, first != " ", first != "\t", first != "-", first != "#", let colon = line.firstIndex(of: ":") else {
                i += 1
                continue
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let rest = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            var end = i + 1
            while end < front.count, Self.continues(front[end], key: rest.isEmpty) { end += 1 }
            let extra = front[(i + 1)..<end]
            found.append(Entry(key: key, range: i..<end, value: Self.value(rest, extra: Array(extra)), inline: rest.hasPrefix("[")))
            i = end
        }
        return found
    }

    private static func continues(_ line: String, key emptyValue: Bool) -> Bool {
        guard let first = line.first else { return true }
        if first == " " || first == "\t" { return true }
        return emptyValue && first == "-"
    }

    private static func value(_ rest: String, extra: [String]) -> BrainProperty.Value {
        let content = extra.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if rest.hasPrefix("["), rest.hasSuffix("]"), content.isEmpty {
            return .list(splitInline(String(rest.dropFirst().dropLast())))
        }
        if rest.isEmpty {
            if content.isEmpty { return .text("") }
            let items = content.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if items.allSatisfy({ $0.hasPrefix("-") }) {
                return .list(items.map { unquote(String($0.dropFirst())) }.filter { !$0.isEmpty })
            }
            return .complex(content.joined(separator: "\n"))
        }
        if !content.isEmpty { return .complex(([rest] + content).joined(separator: "\n")) }
        return .text(unquote(rest))
    }

    private static func splitInline(_ inner: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var quote: Character?
        for character in inner {
            if let open = quote {
                current.append(character)
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
                current.append(character)
            } else if character == "," {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts.map(unquote).filter { !$0.isEmpty }
    }

    private static func unquote(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count >= 2, let first = text.first, first == "\"" || first == "'", text.last == first {
            text = String(text.dropFirst().dropLast())
        }
        return text
    }

    private static func render(_ value: String) -> String {
        let plain = value.isEmpty || value.first.map { !"[{&*!|>%@`'\"#-?:,".contains($0) } == true
        if plain, !value.contains(": "), !value.contains(" #"), value == value.trimmingCharacters(in: .whitespacesAndNewlines) { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    public var properties: [BrainProperty] {
        entries().map { BrainProperty(key: $0.key, value: $0.value) }
    }

    public func property(_ key: String) -> BrainProperty.Value? {
        entries().first { $0.key == key }?.value
    }

    public func list(_ key: String) -> [String] {
        switch property(key) {
        case .list(let items): items
        case .text(let text): text.isEmpty ? [] : [text]
        default: []
        }
    }

    public mutating func set(_ key: String, to value: BrainProperty.Value) {
        var lines = front ?? []
        let carriage = front?.first?.hasSuffix("\r") == true ? "\r" : ""
        let existing = entries().first { $0.key == key }
        let block = existing.map { !$0.inline } ?? true
        var rendered: [String]
        switch value {
        case .text(let text):
            rendered = [text.isEmpty ? "\(key):" : "\(key): \(Self.render(text))"]
        case .list(let items) where items.isEmpty:
            rendered = ["\(key): []"]
        case .list(let items) where !block:
            rendered = ["\(key): [" + items.map(Self.render).joined(separator: ", ") + "]"]
        case .list(let items):
            let indent = existing.flatMap { entry in
                lines[entry.range].dropFirst().first { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("-") }.map { String($0.prefix { $0 == " " || $0 == "\t" }) }
            } ?? "  "
            rendered = ["\(key):"] + items.map { "\(indent)- \(Self.render($0))" }
        case .complex(let raw):
            rendered = ["\(key):"] + BrainText.lines(raw)
        }
        rendered = rendered.map { $0.hasSuffix("\r") || carriage.isEmpty ? $0 : $0 + carriage }
        if let existing {
            lines.replaceSubrange(existing.range, with: rendered)
        } else {
            lines.append(contentsOf: rendered)
        }
        front = lines
    }

    public mutating func remove(_ key: String) {
        guard var lines = front, let existing = entries().first(where: { $0.key == key }) else { return }
        lines.removeSubrange(existing.range)
        front = lines
    }
}
