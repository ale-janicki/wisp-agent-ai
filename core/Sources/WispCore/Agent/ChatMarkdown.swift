import Foundation

public enum ChatMarkdown {
    public enum Segment: Sendable, Equatable {
        case text(String)
        case code(String)
        case table(header: [String], rows: [[String]])
    }

    public static func segments(_ raw: String) -> [Segment] {
        guard raw.contains("```") || raw.contains("~~~") || raw.contains("|") else {
            let plain = raw.trimmingCharacters(in: .newlines)
            return plain.isEmpty ? [] : [.text(plain)]
        }
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var out: [Segment] = []
        var prose: [String] = []
        func flush() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.isEmpty { out.append(.text(joined)) }
            prose = []
        }
        var i = 0
        while i < lines.count {
            if let marker = fenceMarker(lines[i]) {
                flush()
                var body: [String] = []
                i += 1
                while i < lines.count, !isFenceClose(lines[i], marker) {
                    body.append(lines[i])
                    i += 1
                }
                i += 1
                out.append(.code(body.joined(separator: "\n")))
            } else if i + 1 < lines.count, lines[i].contains("|"), isDelimiterRow(lines[i + 1], columns: cells(lines[i]).count) {
                let header = cells(lines[i])
                var rows: [[String]] = []
                var j = i + 2
                while j < lines.count, lines[j].contains("|"), !lines[j].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(cells(lines[j]))
                    j += 1
                }
                flush()
                out.append(.table(header: header, rows: rows))
                i = j
            } else {
                prose.append(lines[i])
                i += 1
            }
        }
        flush()
        return out
    }

    private static func fenceMarker(_ line: String) -> String? {
        var trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3 else { return nil }
        if let marker = listMarkerLength(trimmed) { trimmed = trimmed.dropFirst(marker).drop { $0 == " " } }
        guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let run = trimmed.prefix { $0 == first }
        guard run.count >= 3 else { return nil }
        if first == "`", trimmed.dropFirst(run.count).contains("`") { return nil }
        return String(run)
    }

    private static func listMarkerLength(_ text: Substring) -> Int? {
        let digits = text.prefix { $0.isASCII && $0.isNumber }
        let marker = digits.isEmpty ? text.prefix(1) : text.prefix(digits.count + 1)
        let valid = digits.isEmpty ? ["-", "*", "+"].contains(marker) : (digits.count <= 9 && (marker.last == "." || marker.last == ")"))
        guard valid, text.dropFirst(marker.count).first == " " else { return nil }
        return marker.count
    }

    private static func isFenceClose(_ line: String, _ marker: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let first = marker.first, trimmed.count >= marker.count else { return false }
        return trimmed.allSatisfy { $0 == first }
    }

    private static func isDelimiterRow(_ line: String, columns: Int) -> Bool {
        guard line.contains("|"), line.contains("-") else { return false }
        let parts = cells(line)
        return parts.count == columns && parts.allSatisfy { cell in
            !cell.isEmpty && cell.contains("-") && cell.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var out: [String] = []
        var current = ""
        var escaped = false
        for character in text {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out
    }
}
