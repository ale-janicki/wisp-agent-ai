import Foundation
import Observation
import os
import WispCore

/// "Permissões do Claude": the mode new and resumed Wisp sessions run in. It lives in the profile
/// (`agent.permissionMode`, which the bot reads too); a profile that is a link managed elsewhere is never
/// written through, so there the choice stays in Wisp's own settings. `~/.claude/settings.json` is only read.
@MainActor @Observable
final class PermissionModel {
    static let shared = PermissionModel()

    private(set) var setting = PermissionSetting(choice: .ask, source: .standard)
    /// The profile is a symlink: Wisp keeps the choice in its own settings and the Telegram bot on this Mac reads it from there.
    private(set) var profileIsLink = false
    private(set) var error: String?
    /// A session asked for `auto` and the CLI reported another mode at init.
    private(set) var autoUnavailable = false

    /// The live session restarts with the new mode; set by the conversation model.
    @ObservationIgnored var onChange: () -> Void = {}
    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "permissions")

    private static var claudeSettingsURL: URL {
        let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        let dir = env.map { URL(fileURLWithPath: expandTilde($0), isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude", isDirectory: true)
        return dir.appendingPathComponent("settings.json")
    }

    private var profileURL: URL { ConversationViewModel.profileURL }

    private init() {
        refresh()
    }

    /// The mode for the next session's `--permission-mode`; nil leaves it to the CLI.
    var cliMode: String? {
        PermissionSetting.cliMode(profileMode: profileMode(), wispMode: AppSettings.shared.settings.permissionMode)
    }

    func refresh() {
        profileIsLink = (try? FileManager.default.destinationOfSymbolicLink(atPath: profileURL.path)) != nil
        let claude = PermissionSetting.claudeDefaultMode(settings: try? Data(contentsOf: Self.claudeSettingsURL))
        setting = PermissionSetting.resolve(
            profileMode: profileMode(), wispMode: AppSettings.shared.settings.permissionMode, claudeDefaultMode: claude
        )
    }

    func select(_ choice: PermissionChoice) {
        error = nil
        // The DEBUG setup walkthrough runs on a throwaway home with settings not persisted: never the real profile.
        guard AppSettings.shared.persists else { return }
        if profileIsLink {
            AppSettings.shared.setPermissionMode(choice.rawValue)
        } else {
            do {
                try writeProfile(choice)
                AppSettings.shared.setPermissionMode(nil)
            } catch {
                log.error("profile write failed: \(error.localizedDescription, privacy: .public)")
                self.error = "Não consegui salvar no perfil: \(error.localizedDescription)"
                return
            }
        }
        refresh()
        onChange()
    }

    /// The CLI's answer at init to a session that asked for `requested`.
    func sessionReported(mode: String, requested: String?) {
        guard requested == PermissionChoice.auto.rawValue else { return }
        autoUnavailable = mode != PermissionChoice.auto.rawValue
    }

    private func profileMode() -> String? {
        guard let data = try? Data(contentsOf: profileURL),
              let profile = try? JSONDecoder().decode(Profile.self, from: data) else { return nil }
        return profile.agent.permissionMode
    }

    private func writeProfile(_ choice: PermissionChoice) throws {
        let fm = FileManager.default
        let existing = fm.fileExists(atPath: profileURL.path) ? try Data(contentsOf: profileURL) : nil
        let data = try PermissionSetting.profileData(updating: existing, mode: choice)
        try fm.createDirectory(at: profileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: profileURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: profileURL.path)
    }
}
