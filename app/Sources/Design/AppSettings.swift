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
    @ObservationIgnored private let writeQueue = DispatchQueue(label: "com.owner.wisp.settings.write", qos: .utility)
    @ObservationIgnored private var unsaved = false
    @ObservationIgnored private let log = Logger(subsystem: "com.owner.wisp", category: "settings")

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
            let capture = settings.clipboardCapture
            let spotify = settings.spotifyClientID
            let graph = settings.graph
            settings = .default
            settings.dashboardOrder = order
            settings.telegramOrder = topicOrder
            settings.clipboardCapture = capture
            settings.spotifyClientID = spotify
            settings.graph = graph
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
