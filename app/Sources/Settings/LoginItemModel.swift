import Foundation
import Observation
import os
import ServiceManagement
import WispCore

/// "Abrir ao ligar o Mac" through `SMAppService.mainApp`; `LoginItemPolicy` decides, this only talks to macOS.
@MainActor @Observable
final class LoginItemModel {
    static let shared = LoginItemModel()

    private(set) var status: LoginItemStatus = .notRegistered
    private(set) var error: String?

    @ObservationIgnored private let log = Logger(subsystem: AppIdentity.bundleID, category: "login-item")

    let installed = LoginItemPolicy.isInstalled(
        bundle: Bundle.main.bundleURL,
        home: FileManager.default.homeDirectoryForCurrentUser
    )

    init() { refresh() }

    func refresh() {
        status = switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        default: .notRegistered
        }
    }

    var isOn: Bool { LoginItemPolicy.isOn(status) }

    var removedByUser: Bool {
        let settings = AppSettings.shared.settings
        return LoginItemPolicy.removedByUser(wanted: settings.openAtLogin, status: status, registeredBefore: settings.loginItemRegistered)
    }

    /// Launch and the wizard's finish: registers once; afterwards only a switch turned off is carried out.
    func sync(setupFinished: Bool) {
        refresh()
        let settings = AppSettings.shared.settings
        perform(LoginItemPolicy.action(
            wanted: settings.openAtLogin, setupFinished: setupFinished, installed: installed, status: status,
            registeredBefore: settings.loginItemRegistered
        ))
    }

    /// The Ajustes switch: the user asks on purpose, so it registers even after a removal in System Settings.
    func set(_ on: Bool) {
        AppSettings.shared.setOpenAtLogin(on)
        refresh()
        perform(LoginItemPolicy.action(wanted: on, setupFinished: true, installed: installed, status: status, registeredBefore: false))
    }

    func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func perform(_ action: LoginItemAction) {
        guard action != .nothing else { return }
        do {
            if action == .register {
                try SMAppService.mainApp.register()
                AppSettings.shared.markLoginItemRegistered()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            log.error("login item \(String(describing: action), privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            self.error = "Não consegui ajustar a abertura ao ligar o Mac: \(error.localizedDescription)"
        }
        refresh()
        log.info("login item \(String(describing: action), privacy: .public) -> \(String(describing: self.status), privacy: .public)")
    }
}
