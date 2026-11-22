import Foundation

public enum EngineGuards {
    public static let matcher = "Bash|Read|Edit|MultiEdit|Write|NotebookEdit|Grep|Glob"
    public static let hooks = ["guard-secrets", "guard-telegram", "guard-destructive", "guard-lessons", "guard-agenda", "guard-outbound"]
    public static let recallTimeout = 5
    public static let askRules = ["Bash(*aprender add*)", "Bash(*aprender confirmar*)", "Bash(*aprender descartar*)",
                                    "Bash(*topic unir*--aplicar*)", "Bash(*topic unir*--forcar*)"]

    static let agendaAsk = ["criar-evento", "editar-evento", "apagar-evento", "criar-lembrete", "concluir-lembrete", "permissao --pedir"]
    static let agendaHeads = ["\"$WISP_BIN\" agenda", "$WISP_BIN agenda", "wisp agenda", "\"$WISP_AGENDA_BIN\""]
    public static let agendaAskRules = agendaAsk.flatMap { sub in agendaHeads.map { "Bash(\($0) \(sub):*)" } }
    public static let askTools = ["mcp__wisp-email__email_send", "mcp__wisp-mac__mac_send"]
    public static let denyRules = [
        "Write(~/Library/Preferences/ai.wisp.app.plist)",
        "Edit(~/Library/Preferences/ai.wisp.app.plist)",
        "Write(~/Library/Application Support/Wisp/**)",
        "Edit(~/Library/Application Support/Wisp/**)",
        "Write(~/.config/wisp/**)",
        "Edit(~/.config/wisp/**)",
        "Write(~/.local/state/wisp/mac-callers/**)",
        "Edit(~/.local/state/wisp/mac-callers/**)",
        "Bash(*defaults*ai.wisp.app*)",
        "Bash(*Preferences/ai.wisp.app*)",
        "Bash(*ai.wisp.app.plist*)",
        "Bash(plutil*ai.wisp.app*)",
        "Bash(*PlistBuddy*ai.wisp.app*)",
    ]

    public static func settings(wispBinary: String) -> [String: Any] {
        let quoted = "'" + wispBinary.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let commands = hooks.map { ["type": "command", "command": "\(quoted) hook \($0)"] }
        let recall: [[String: Any]] = [["type": "command", "command": "\(quoted) hook recall", "timeout": recallTimeout]]
        let lessons: [[String: Any]] = [["type": "command", "command": "\(quoted) hook aprendizados", "timeout": recallTimeout]]
        return ["permissions": ["ask": askRules + agendaAskRules + askTools, "deny": denyRules], "hooks": [
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
