import Foundation

public enum CodexCommand {
    public static let readOnly = ["--sandbox", "read-only"]
    public static let workspaceWrite = ["--sandbox", "workspace-write"]

    public static func sandboxArguments(_ choice: PermissionChoice?) -> [String] {
        switch choice {
        case .auto, .bypass: workspaceWrite
        case .ask, nil: readOnly
        }
    }

    public static func safeDirectory(_ raw: String?, home: String = NSHomeDirectory()) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let homePath = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        let path = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue,
              path != "/", path != homePath, !homePath.hasPrefix(path + "/") else { return nil }
        return path
    }

    public static func workspace(preferred: String?, home: String = NSHomeDirectory(), wispDir: String) -> String? {
        safeDirectory(preferred, home: home) ?? safeDirectory(wispDir, home: home)
    }

    public static func extraDirectories(workspace: String, candidates: [String], home: String = NSHomeDirectory()) -> [String] {
        let root = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().path
        var out: [String] = []
        for candidate in candidates {
            guard let path = safeDirectory(candidate, home: home), path != root, !path.hasPrefix(root + "/"),
                  !out.contains(path) else { continue }
            out.append(path)
        }
        return out
    }

    public static func configuredModel(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let codexHome = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? home.appendingPathComponent(".codex")
        guard let data = FileManager.default.contents(atPath: codexHome.appendingPathComponent("config.toml").path) else { return "" }
        return EngineChoice.topLevelString(String(decoding: data, as: UTF8.self), key: "model") ?? ""
    }

    public static func tomlString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    public static let emailServer = "wisp-email"
    public static let brainServer = "wisp-brain"
    public static let macServer = "wisp-mac"

    public static let macReadOnlyTools = [
        "mac_apps", "mac_battery", "mac_dnd_status", "mac_screenshot", "mac_shortcuts_list", "mac_ui_tree", "mac_wifi", "mac_windows",
    ]
    public static let macAllTools = [
        "mac_app", "mac_apps", "mac_battery", "mac_brightness", "mac_dark_mode", "mac_dnd_status", "mac_media", "mac_notify",
        "mac_open", "mac_open_url", "mac_screenshot", "mac_script", "mac_send", "mac_settings_pane", "mac_shortcut",
        "mac_shortcuts_list", "mac_ui_click", "mac_ui_key", "mac_ui_menu", "mac_ui_scroll", "mac_ui_tree", "mac_ui_type",
        "mac_volume", "mac_wifi", "mac_windows",
    ]

    public static func changesAllowed(_ choice: PermissionChoice?) -> Bool {
        choice == .auto || choice == .bypass
    }

    public static func mcpOverrides(wispBinary: String, ownedByUser: Set<String> = [], allowChanges: Bool = true) -> [String] {
        let macTools = "[" + (allowChanges ? macAllTools : macReadOnlyTools).map { "\"\($0)\"" }.joined(separator: ", ") + "]"
        func fields(_ server: String, env: String, timeout: String = "660", tools: String? = nil) -> [(String, String)] {
            [
                ("command", tomlString(wispBinary)),
                ("args", #"["mcp", "\#(server)"]"#),
                ("env_vars", env),
                ("default_tools_approval_mode", #""approve""#),
                ("startup_timeout_sec", "30"),
                ("tool_timeout_sec", timeout),
            ] + (tools.map { [("enabled_tools", $0)] } ?? []) + [("enabled", "true")]
        }
        let socket = ApprovalBroker.socketEnvironment
        var out = fields("email", env: #"["WISP_TELEGRAM_THREAD", "\#(socket)"]"#).map { "mcp_servers.\(emailServer).\($0.0)=\($0.1)" }
        if !ownedByUser.contains(brainServer) {
            out += fields("brain", env: #"["WISP_CONFIG", "XDG_CONFIG_HOME", "XDG_STATE_HOME"]"#, timeout: "60").map { "mcp_servers.\(brainServer).\($0.0)=\($0.1)" }
        }
        if !ownedByUser.contains(macServer) {
            out += fields("mac", env: #"["WISP_TELEGRAM_THREAD", "\#(socket)"]"#, tools: macTools).map { "mcp_servers.\(macServer).\($0.0)=\($0.1)" }
        }
        return out
    }

    public static func environment(
        executable: URL, overrides: [String: String] = [:], wispBinary: String? = nil,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        if let path = ClaudeLocator.cachedLoginShellPATH {
            env["PATH"] = path
        } else {
            let existing = env["PATH"] ?? "/usr/bin:/bin"
            env["PATH"] = existing + ":" + executable.deletingLastPathComponent().path + ":/opt/homebrew/bin:/usr/local/bin"
        }
        for (key, value) in overrides { env[key] = value }
        if let wispBinary, !wispBinary.isEmpty { env["WISP_BIN"] = wispBinary }
        return env
    }

    public static func arguments(
        workspace: String, permission: PermissionChoice?, addDirs: [String] = [], instructions: String = "",
        wispBinary: String, resume: String? = nil, ownedByUser: Set<String> = []
    ) -> [String] {
        var args = ["exec", "--json", "--skip-git-repo-check", "-C", workspace] + sandboxArguments(permission)
        for directory in addDirs { args += ["--add-dir", directory] }
        if !instructions.isEmpty { args += ["-c", "developer_instructions=\(tomlString(instructions))"] }
        for override in mcpOverrides(wispBinary: wispBinary, ownedByUser: ownedByUser, allowChanges: changesAllowed(permission)) { args += ["-c", override] }
        if let resume { args += ["resume", resume] }
        return args + ["-"]
    }
}
