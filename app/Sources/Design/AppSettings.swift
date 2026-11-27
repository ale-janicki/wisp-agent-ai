import Foundation
import Observation
import os
import WispCore

@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    private(set) var settings: WispSettings
    private(set) var colors: ThemeColors
    private(set) var notice: String?

    @ObservationIgnored private let store: SettingsStore
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let writeQueue = DispatchQueue(label: "\(AppIdentity.bundleID).settings.write", qos: .utility)
    @ObservationIgnored private var unsaved = false
    @ObservationIgnored var persists = true
    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "settings")

    private static let saveDelay: Duration = .milliseconds(400)

    init(store: SettingsStore = SettingsStore()) {
        self.store = store
        settings = store.settings
        colors = store.settings.colors
        notice = store.lastRecoveryNote
    }

    func selectPreset(_ preset: ThemePreset) {
        update { $0.theme = preset.id }
    }

    func selectCustom() {
        let current = colors
        update { settings in
            settings.theme = WispSettings.customTheme
            if settings.custom == nil {
                settings.custom = CustomTheme(accent: current.accent, background: current.background, surface: current.surface)
            }
        }
    }

    func setCustom(_ keyPath: WritableKeyPath<CustomTheme, HexColor>, to color: HexColor) {
        let current = colors
        update { settings in
            var custom = settings.custom ?? CustomTheme(accent: current.accent, background: current.background, surface: current.surface)
            custom[keyPath: keyPath] = color
            settings.custom = custom
            settings.theme = WispSettings.customTheme
        }
    }

    func restoreDefaults() {
        update { settings in
            let order = settings.dashboardOrder
            let topicOrder = settings.telegramOrder
            let pins = settings.pinnedConversations
            let capture = settings.clipboardCapture
            let spotify = settings.spotifyClientID
            let graph = settings.graph
            let notices = settings.notices
            let openAtLogin = settings.openAtLogin
            let loginItemRegistered = settings.loginItemRegistered
            let section = settings.settingsSection
            let agenda = settings.agenda
            let meetings = settings.meetings
            let brainShowsGraph = settings.brainShowsGraph
            let windowMode = settings.windowMode
            let terminalBlocks = settings.terminalBlocks
            let terminalNativeBlocks = settings.terminalNativeBlocks
            let terminalInteractiveCommands = settings.terminalInteractiveCommands
            settings = .default
            settings.dashboardOrder = order
            settings.telegramOrder = topicOrder
            settings.pinnedConversations = pins
            settings.clipboardCapture = capture
            settings.spotifyClientID = spotify
            settings.graph = graph
            settings.notices = notices
            settings.openAtLogin = openAtLogin
            settings.loginItemRegistered = loginItemRegistered
            settings.settingsSection = section
            settings.agenda = agenda
            settings.meetings = meetings
            settings.brainShowsGraph = brainShowsGraph
            settings.terminalBlocks = terminalBlocks
            settings.terminalNativeBlocks = terminalNativeBlocks
            settings.terminalInteractiveCommands = terminalInteractiveCommands
            settings.windowMode = windowMode
        }
    }

    func setDashboardOrder(_ order: [String]) {
        update { $0.dashboardOrder = order }
    }

    func restoreDashboardOrder() {
        update { $0.dashboardOrder = DashboardTileID.defaultOrder }
    }

    func setTelegramOrder(_ order: [Int]) {
        update { $0.telegramOrder = order }
    }

    func setPinnedConversations(_ pins: [String]) {
        update { $0.pinnedConversations = pins }
    }

    func togglePin(_ key: String) {
        update { settings in
            if settings.pinnedConversations.contains(key) {
                settings.pinnedConversations.removeAll { $0 == key }
            } else {
                settings.pinnedConversations.append(key)
            }
        }
    }

    func restoreTelegramOrder() {
        update { $0.telegramOrder = [] }
    }

    func setClipboardCapture(_ on: Bool) {
        update { $0.clipboardCapture = on }
    }

    func setSpotifyClientID(_ id: String) {
        update { $0.spotifyClientID = id.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func setGraph(_ change: (inout GraphControls) -> Void) {
        update { change(&$0.graph) }
    }

    func setWindowMode(_ on: Bool) {
        update { $0.windowMode = on }
    }

    func setOpenAtLogin(_ on: Bool) {
        update { $0.openAtLogin = on }
    }

    func markLoginItemRegistered() {
        update { $0.loginItemRegistered = true }
    }

    func setNotices(_ change: (inout NoticeSettings) -> Void) {
        update { change(&$0.notices) }
    }

    func setMeetings(_ change: (inout MeetingSettings) -> Void) {
        update { change(&$0.meetings) }
    }

    func setPermissionMode(_ mode: String?) {
        update { $0.permissionMode = mode }
    }

    func setAgenda(_ change: (inout AgendaPreferences) -> Void) {
        update { change(&$0.agenda) }
    }

    func setTerminalBlocks(_ on: Bool) {
        update { $0.terminalBlocks = on }
    }

    func setTerminalNativeBlocks(_ on: Bool) {
        update { $0.terminalNativeBlocks = on }
    }

    func setSettingsSection(_ id: String) {
        update { $0.settingsSection = id }
    }

    #if DEBUG
    func applyForSnapshot(_ settings: WispSettings) {
        self.settings = settings
        colors = settings.colors
    }
    #endif

    private func update(_ change: (inout WispSettings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        colors = next.colors
        scheduleSave()
    }

    private func scheduleSave() {
        guard persists else { return }
        saveTask?.cancel()
        unsaved = true
        let snapshot = settings
        let store = store
        let queue = writeQueue
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            let failure = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                queue.async {
                    do {
                        try store.save(snapshot)
                        continuation.resume(returning: nil)
                    } catch {
                        continuation.resume(returning: error.localizedDescription)
                    }
                }
            }
            guard let self else { return }
            if let failure {
                self.log.error("settings save failed: \(failure, privacy: .public)")
                self.notice = "Não consegui salvar os ajustes: \(failure)"
            } else {
                if snapshot == self.settings { self.unsaved = false }
                self.notice = nil
            }
        }
    }

    func flush() {
        guard unsaved else { return }
        saveTask?.cancel()
        let snapshot = settings
        let store = store
        do {
            try writeQueue.sync { try store.save(snapshot) }
            unsaved = false
        } catch {
            log.error("settings flush failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
