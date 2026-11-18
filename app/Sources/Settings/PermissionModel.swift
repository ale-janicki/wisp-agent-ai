import Foundation
import Observation
import os
import WispCore

@MainActor @Observable
final class PermissionModel {
    static let shared = PermissionModel()

    private(set) var setting = PermissionSetting(choice: .ask, source: .standard)
    private(set) var profileIsLink = false
    private(set) var error: String?
    private(set) var autoUnavailable = false

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
