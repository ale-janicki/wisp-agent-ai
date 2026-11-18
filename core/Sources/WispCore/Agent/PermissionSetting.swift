import Foundation

public enum PermissionChoice: String, CaseIterable, Sendable {
    case ask = "default"
    case auto
    case bypass = "bypassPermissions"

    public init?(mode: String) {
        switch mode {
        case "default", "manual": self = .ask
        case "auto": self = .auto
        case "bypassPermissions": self = .bypass
        default: return nil
        }
    }
}

public struct PermissionSetting: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case profile
        case wisp
        case claude(String)
        case standard
    }

    public var choice: PermissionChoice?
    public var source: Source

    public init(choice: PermissionChoice?, source: Source) {
        self.choice = choice
        self.source = source
    }

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

    public static func cliMode(profileMode: String?, wispMode: String? = nil) -> String? {
        (wispMode.flatMap(PermissionChoice.init(mode:)) ?? profileMode.flatMap(PermissionChoice.init(mode:)))?.rawValue
    }

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
