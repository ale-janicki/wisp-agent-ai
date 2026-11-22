import Foundation

public enum BrainText {
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    public static func stem(of path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    public static func withoutMarkdownSuffix(_ path: String) -> String {
        path.lowercased().hasSuffix(".md") ? String(path.dropLast(3)) : path
    }

    public static func isMarkdown(_ path: String) -> Bool {
        path.lowercased().hasSuffix(".md")
    }

    public static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    public static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    static func trimmed(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var lower = bytes.startIndex, upper = bytes.endIndex
        while lower < upper, bytes[lower] == 0x20 || bytes[lower] == 0x09 { lower += 1 }
        while upper > lower, bytes[upper - 1] == 0x20 || bytes[upper - 1] == 0x09 { upper -= 1 }
        return bytes[lower..<upper]
    }
}
