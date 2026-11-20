import Foundation

public enum EngineGuards {
    public static let matcher = "Bash|Read|Edit|MultiEdit|Write|NotebookEdit|Grep|Glob"
    public static let hooks = ["guard-secrets", "guard-telegram", "guard-destructive"]
    public static let recallTimeout = 5

    public static func settings(wispBinary: String) -> [String: Any] {
        let quoted = "'" + wispBinary.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let commands = hooks.map { ["type": "command", "command": "\(quoted) hook \($0)"] }
        let recall: [[String: Any]] = [["type": "command", "command": "\(quoted) hook recall", "timeout": recallTimeout]]
        let lessons: [[String: Any]] = [["type": "command", "command": "\(quoted) hook aprendizados", "timeout": recallTimeout]]
        return ["hooks": [
            "PreToolUse": [["matcher": matcher, "hooks": commands]],
            "UserPromptSubmit": [["hooks": recall]],
            "SessionStart": [["hooks": lessons]],
        ]]
    }

    public static func install(wispBinary: String, at url: URL) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: settings(wispBinary: wispBinary), options: [.prettyPrinted, .sortedKeys])
        if let current = try? Data(contentsOf: url), current == data { return url }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    public static func wispBinary(telegramBinary: String?, layout: RuntimeLayout) -> String? {
        if let telegramBinary, !telegramBinary.isEmpty { return telegramBinary }
        let candidates = [layout.wisp, layout.home.appendingPathComponent(".local/bin/wisp")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }?.path
    }

    public static func settingsURL(home: URL) -> URL {
        home.appendingPathComponent(".local/state/wisp/guard-settings-app.json")
    }
}
