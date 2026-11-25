import Foundation

public enum CommandSyntax {
    public enum Kind: Equatable, Sendable {
        case command(resolved: Bool)
        case string
        case flag
        case path
        case plain
    }

    public struct Span: Equatable, Sendable {
        public let range: Range<Int>
        public let kind: Kind
    }

    private static let prefixes: Set<String> = [
        "sudo", "time", "exec", "command", "builtin", "nohup", "nice", "env", "xargs", "then", "do", "else", "elif", "if", "while", "until",
        "!", "{",
    ]

    public static func spans(
        _ text: String, isProgram: (String) -> Bool, isPrefixOfProgram: (String) -> Bool = { _ in false }
    ) -> [Span] {
        let units = Array(text.utf16)
        var spans = [Span]()
        var index = 0
        var commandPosition = true
        while index < units.count {
            let unit = units[index]
            if unit == 0x0A || unit == 0x3B || unit == 0x7C || unit == 0x26 || unit == 0x28 {
                commandPosition = true
                index += 1
                continue
            }
            if isSpace(unit) || unit == 0x29 || unit == 0x3C || unit == 0x3E {
                index += 1
                continue
            }
            let start = index
            var quoted = false
            var quote: UInt16 = 0
            while index < units.count {
                let current = units[index]
                if quote != 0 {
                    if current == 0x5C, quote == 0x22, index + 1 < units.count { index += 1 } else if current == quote { quote = 0 }
                } else if current == 0x27 || current == 0x22 {
                    quote = current
                    if index == start { quoted = true }
                } else if current == 0x5C, index + 1 < units.count {
                    index += 1
                } else if isSpace(current) || current == 0x0A || current == 0x3B || current == 0x7C || current == 0x26
                            || current == 0x29 || current == 0x3C || current == 0x3E {
                    break
                }
                index += 1
            }
            index = min(index, units.count)
            let word = String(decoding: units[start..<index], as: UTF16.self)
            let complete = index < units.count
            if commandPosition, !quoted, isAssignment(word) {
                continue
            }
            if quoted {
                spans.append(Span(range: start..<index, kind: .string))
                commandPosition = false
            } else if commandPosition {
                let resolved = word.contains("/") || word.hasPrefix("~") || isProgram(word) || (!complete && isPrefixOfProgram(word))
                spans.append(Span(range: start..<index, kind: .command(resolved: resolved)))
                commandPosition = prefixes.contains(word)
            } else if word.hasPrefix("-"), word.count > 1 {
                spans.append(Span(range: start..<index, kind: .flag))
            } else if word.hasPrefix("/") || word.hasPrefix("~") || word.hasPrefix("./") || word.hasPrefix("../") {
                spans.append(Span(range: start..<index, kind: .path))
            }
        }
        return spans
    }

    private static func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[word.startIndex..<equals]
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" } && !(name.first?.isNumber ?? false)
    }
}
