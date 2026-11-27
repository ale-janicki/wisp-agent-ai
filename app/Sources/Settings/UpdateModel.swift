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

    // A scheduled check must not leave a Sparkle session open: that session keeps the item it found, and a later
    // checkForUpdates() only re-shows it (SPUUpdater.checkForUpdates: driver.showingUpdate -> showUpdateInFocus)
    // instead of fetching the appcast. So scheduled finds become a Wisp notice and the session ends here.
    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        let shown = updateItem.displayVersionString
        let isNew = available != shown
        available = shown
        guard updateCheck == .updatesInBackground, notices != nil else { return }
        if isNew {
            notices?.post(Notice(
                sourceId: "update",
                kind: .update,
                title: "Versão nova do Wisp — \(shown)",
                preview: "Clique para ver as novidades e instalar.",
                time: Date(),
                target: .update
            ))
        }
        throw NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue))
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        log.info("update found \(item.displayVersionString, privacy: .public) (\(item.versionString, privacy: .public))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        log.info("no update")
        available = nil
    }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        if choice == .skip { available = nil }
    }
}

extension UpdateModel: @MainActor SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate { NSApp.activate() }
    }

    func standardUserDriverWillShowModalAlert() {
        NSApp.activate()
    }
}
