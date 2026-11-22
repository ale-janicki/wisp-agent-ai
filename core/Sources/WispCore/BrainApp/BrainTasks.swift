import Foundation

public enum BrainTasks {
    private static let pattern = try! NSRegularExpression(pattern: #"^[ \t>]*(?:[-*+]|\d+[.)])[ \t]+\[([ xX])\](?:[ \t]|$)"#)

    public static func normalized(_ line: String) -> String {
        var text = Substring(line)
        while let first = text.first, first == " " || first == "\t" || first == ">" { text = text.dropFirst() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func toggle(in text: String, line: Int, expected: String? = nil) -> String? {
        var lines = BrainText.lines(text)
        guard lines.indices.contains(line) else { return nil }
        let current = lines[line]
        if let expected, normalized(current) != normalized(expected) { return nil }
        let whole = NSRange(current.startIndex..., in: current)
        guard let match = pattern.firstMatch(in: current, range: whole), let box = Range(match.range(at: 1), in: current) else { return nil }
        lines[line].replaceSubrange(box, with: current[box] == " " ? "x" : " ")
        return lines.joined(separator: "\n")
    }
}
