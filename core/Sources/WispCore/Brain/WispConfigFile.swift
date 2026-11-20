import Foundation

public struct WispConfigFile: Sendable {
    public enum Failure: Error, Equatable {
        case isSymlink
        case unreadable
    }

    public static let defaultURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/wisp/wisp.json")

    public let url: URL

    public init(url: URL = WispConfigFile.defaultURL) {
        self.url = url
    }

    public func string(_ key: String) -> String? {
        (try? read())?[key] as? String
    }

    public func bool(_ key: String, default fallback: Bool) -> Bool {
        (try? read())?[key] as? Bool ?? fallback
    }

    public func setString(_ key: String, to value: String) throws {
        try update { $0[key] = value }
    }

    public func setBool(_ key: String, to value: Bool) throws {
        try update { $0[key] = value }
    }

    private func read() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw Failure.unreadable
        }
        return object
    }

    func update(_ change: (inout [String: Any]) -> Void) throws {
        let fm = FileManager.default
        if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil { throw Failure.isSymlink }
        var object = try read()
        change(&object)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let mode = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = url.deletingLastPathComponent().appendingPathComponent(".wisp.json.\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: staged.path, contents: data + Data("\n".utf8), attributes: [.posixPermissions: mode]) else {
            throw Failure.unreadable
        }
        do {
            _ = try fm.replaceItemAt(url, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }
}
