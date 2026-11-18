import AppKit
import Observation
import os
import Sparkle
import WispCore

@MainActor @Observable
final class UpdateModel: NSObject {
    static let shared = UpdateModel()

    private(set) var available: String?
    private(set) var automaticChecks = false

    @ObservationIgnored weak var notices: NoticeCenter?
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "update")

    let version: String = {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }()

    func start() {
        guard controller == nil else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        automaticChecks = controller.updater.automaticallyChecksForUpdates
        log.info("updater started, feed \(controller.updater.feedURL?.absoluteString ?? "none", privacy: .public)")
        #if DEBUG
        if Self.debugFeed != nil { controller.updater.checkForUpdatesInBackground() }
        #endif
    }

    #if DEBUG
    private static var debugFeed: String? {
        guard let feed = UserDefaults.standard.string(forKey: "WispUpdateFeed"), !feed.isEmpty else { return nil }
        return feed
    }
    #endif

    func showUpdate() {
        guard let controller else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    func setAutomaticChecks(_ on: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = on
        automaticChecks = updater.automaticallyChecksForUpdates
    }
}

extension UpdateModel: @MainActor SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
        return Self.debugFeed
        #else
        return nil
        #endif
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log.info("update found \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        log.info("no update")
    }
}

extension UpdateModel: @MainActor SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        notices == nil
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate {
            NSApp.activate()
            return
        }
        let shown = update.displayVersionString
        available = shown
        notices?.post(Notice(
            sourceId: "update",
            kind: .update,
            title: "Versão nova do Wisp — \(shown)",
            preview: "Clique para ver as novidades e instalar.",
            time: Date(),
            target: .update
        ))
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        available = nil
    }

    func standardUserDriverWillFinishUpdateSession() {
        available = nil
    }

    func standardUserDriverWillShowModalAlert() {
        NSApp.activate()
    }
}
