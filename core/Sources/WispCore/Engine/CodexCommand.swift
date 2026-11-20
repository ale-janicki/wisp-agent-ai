import Foundation

public enum CodexCommand {
    public static let readOnly = ["--sandbox", "read-only"]
    public static let autoReview = ["--approve-for-me"]
    public static let workspaceWrite = ["--sandbox", "workspace-write"]

    public static func sandboxArguments(_ choice: PermissionChoice?) -> [String] {
        switch choice {
        case .auto: autoReview
        case .bypass: workspaceWrite
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

    public static func arguments(
        workspace: String, permission: PermissionChoice?, addDirs: [String] = [], instructions: String = "",
        resume: String? = nil
    ) -> [String] {
        var args = ["exec", "--json", "--skip-git-repo-check", "-C", workspace] + sandboxArguments(permission)
        for directory in addDirs { args += ["--add-dir", directory] }
        if !instructions.isEmpty { args += ["-c", "developer_instructions=\(tomlString(instructions))"] }
        if let resume { args += ["resume", resume] }
        return args + ["-"]
    }
}
