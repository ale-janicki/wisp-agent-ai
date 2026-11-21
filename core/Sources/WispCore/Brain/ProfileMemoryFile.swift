import Foundation

public struct ProfileMemoryFile: Sendable {
    public let url: URL

    public init(url: URL = ProfileLoader.defaultURL) {
        self.url = url
    }

    @discardableResult
    public func setRoot(_ root: String) throws -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true, values.isRegularFile == true else { return false }
        try WispConfigFile(url: url).update { object in
            var blocks = object["blocks"] as? [String: Any] ?? [:]
            var memory = blocks["memory"] as? [String: Any] ?? [:]
            let oldTasks = (memory["root"] as? String).map { Self.tasksFile(in: $0) }
            memory["root"] = root
            blocks["memory"] = memory
            var tasks = blocks["tasks"] as? [String: Any]
            if let oldTasks, let current = tasks?["file"] as? String, Self.same(current, oldTasks) {
                tasks?["file"] = Self.tasksFile(in: root)
                blocks["tasks"] = tasks
            }
            object["blocks"] = blocks
        }
        return true
    }

    private static func tasksFile(in root: String) -> String {
        URL(fileURLWithPath: root).appendingPathComponent("pendencias.md").path
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: (a as NSString).expandingTildeInPath).standardized.path
            == URL(fileURLWithPath: (b as NSString).expandingTildeInPath).standardized.path
    }
}
