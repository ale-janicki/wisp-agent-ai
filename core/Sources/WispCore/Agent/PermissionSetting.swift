import Foundation

/// The three choices Wisp offers; the raw value is the CLI's `--permission-mode` value.
public enum PermissionChoice: String, CaseIterable, Sendable {
    case ask = "default"
    case auto
    case bypass = "bypassPermissions"

    /// A CLI mode name as Wisp's choice; `manual` is the CLI's other name for `default`. Other modes have no choice.
    public init?(mode: String) {
        switch mode {
        case "default", "manual": self = .ask
        case "auto": self = .auto
        case "bypassPermissions": self = .bypass
        default: return nil
        }
    }
}

/// Which permission mode a Wisp session runs in and where it came from.
public struct PermissionSetting: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        /// `agent.permissionMode` in the profile.
        case profile
        /// Wisp's own settings: chosen in Wisp while the profile could not be written (a link managed elsewhere).
        case wisp
        /// `permissions.defaultMode` in the user's `~/.claude/settings.json`; Wisp passes no mode and the CLI applies it.
        case claude(String)
        /// Neither: the CLI's own default, which asks.
        case standard
    }

    /// nil when the Claude setting is a mode Wisp has no choice for (acceptEdits, plan, dontAsk).
    public var choice: PermissionChoice?
    public var source: Source

    public init(choice: PermissionChoice?, source: Source) {
        self.choice = choice
        self.source = source
    }

    /// Wisp's own choice wins (it only exists while the profile cannot take it), then the profile, then Claude's
    /// settings; an unknown value counts as unset.
    public static func resolve(profileMode: String?, wispMode: String? = nil, claudeDefaultMode: String?) -> PermissionSetting {
        if let wispMode, let choice = PermissionChoice(mode: wispMode) {
            return PermissionSetting(choice: choice, source: .wisp)
        }
        if let profileMode, let choice = PermissionChoice(mode: profileMode) {
            return PermissionSetting(choice: choice, source: .profile)
        }
        if let claudeDefaultMode, !claudeDefaultMode.isEmpty {
            return PermissionSetting(choice: PermissionChoice(mode: claudeDefaultMode), source: .claude(claudeDefaultMode))
        }
        return PermissionSetting(choice: .ask, source: .standard)
    }

    /// The `--permission-mode` value for a session; nil leaves it to the CLI (its settings or its default).
    public static func cliMode(profileMode: String?, wispMode: String? = nil) -> String? {
        (wispMode.flatMap(PermissionChoice.init(mode:)) ?? profileMode.flatMap(PermissionChoice.init(mode:)))?.rawValue
    }

    /// `permissions.defaultMode` of a Claude settings file; nil when absent or unreadable.
    public static func claudeDefaultMode(settings data: Data?) -> String? {
        guard let data,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let permissions = object["permissions"] as? [String: Any],
              let mode = permissions["defaultMode"] as? String, !mode.isEmpty else { return nil }
        return mode
    }

    public enum WriteError: Error, Equatable, LocalizedError {
        case notAnObject

        public var errorDescription: String? { "o perfil existente não tem o formato esperado" }
    }

    /// Profile text with `agent.permissionMode` set and every other key kept. No profile yet gets the defaults
    /// the app needs to decode it (the profile step fills them in later), like the CLI's Telegram writer.
    public static func profileData(updating data: Data?, mode: PermissionChoice) throws -> Data {
        var profile: [String: Any] = [:]
        if let data, !data.isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw WriteError.notAnObject }
            profile = object
        }
        if profile["persona"] as? [String: Any] == nil { profile["persona"] = ["name": "Wisp", "language": "pt-BR"] }
        var agent = profile["agent"] as? [String: Any] ?? [:]
        if agent["cwd"] as? String == nil { agent["cwd"] = "~" }
        agent["permissionMode"] = mode.rawValue
        profile["agent"] = agent
        var out = try JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        out.append(0x0A)
        return out
    }
}
