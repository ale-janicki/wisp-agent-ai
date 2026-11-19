import Foundation

public enum FileLinks {
    public static let maxFiles = 10
    public static let maxBytes = 50 * 1024 * 1024

    public static func absolutePaths(in text: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let denied = [".ssh", ".gnupg", ".aws", "Library/Keychains", ".config/wisp"]
            .map { home.appendingPathComponent($0).resolvingSymlinksInPath().path }
        let deniedIDs = denied.compactMap { fileID($0) }
        var seen = Set<String>()
        var out: [String] = []
        for token in candidates(in: text) {
            guard let url = URL(string: token), url.isFileURL else { continue }
            let path = url.path
            guard path.hasPrefix("/") else { continue }
            let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            if isDenied(real, denied: denied, deniedIDs: deniedIDs) { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: real),
                  let size = (try? FileManager.default.attributesOfItem(atPath: real))?[.size] as? Int, size <= maxBytes
            else { continue }
            guard seen.insert(real).inserted else { continue }
            out.append(path)
            if out.count == maxFiles { break }
        }
        return out
    }

    private static func isDenied(_ real: String, denied: [String], deniedIDs: [NSObject]) -> Bool {
        let folded = real.lowercased()
        for root in denied {
            let rootFolded = root.lowercased()
            if folded == rootFolded || folded.hasPrefix(rootFolded + "/") { return true }
        }
        var url = URL(fileURLWithPath: real)
        while url.path != "/" {
            if let id = fileID(url.path), deniedIDs.contains(where: { $0.isEqual(id) }) { return true }
            url.deleteLastPathComponent()
        }
        return false
    }

    private static func fileID(_ path: String) -> NSObject? {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier as? NSObject
    }

    private static func candidates(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"file://[^\s)>"'\]]+"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}
