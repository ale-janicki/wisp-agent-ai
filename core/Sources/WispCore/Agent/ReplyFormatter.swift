import Foundation

public enum ReplyFormatter {
    public static func split(_ text: String, statusPrefix: String?) -> (body: String, status: String?) {
        guard let statusPrefix else { return (text, nil) }
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let index = lines.firstIndex(where: { $0.hasPrefix(statusPrefix) }) else { return (text, nil) }
        let status = lines[index].dropFirst(statusPrefix.count).trimmingCharacters(in: .whitespaces)
        var body = lines[..<index].joined(separator: "\n")
        while let last = body.last, last.isWhitespace { body.removeLast() }
        return (body, status)
    }
}
