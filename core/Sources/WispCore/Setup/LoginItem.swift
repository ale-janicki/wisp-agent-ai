import Foundation

/// The app's own login item status, as `SMAppService` reports it.
public enum LoginItemStatus: Sendable, Equatable {
    case notRegistered, enabled, requiresApproval, notFound
}

public enum LoginItemAction: Sendable, Equatable {
    case register, unregister, nothing
}

/// "Abrir ao ligar o Mac". Pure: the app owns `SMAppService`, the bundle path and the setting.
public enum LoginItemPolicy {
    /// Only an app in /Applications or ~/Applications is a login item; a dev build in DerivedData never becomes one.
    public static func isInstalled(bundle: URL, home: URL) -> Bool {
        let path = bundle.standardizedFileURL.resolvingSymlinksInPath().path
        let roots = ["/Applications", home.standardizedFileURL.appendingPathComponent("Applications").path]
        return roots.contains { path.hasPrefix($0 + "/") }
    }

    /// Registers once: after the first success (`registeredBefore`) a removal in System Settings stays removed;
    /// only switching it off in Ajustes still unregisters. The Ajustes switch asks again by passing false.
    public static func action(
        wanted: Bool, setupFinished: Bool, installed: Bool, status: LoginItemStatus, registeredBefore: Bool
    ) -> LoginItemAction {
        guard installed else { return .nothing }
        switch (wanted, status) {
        case (true, .notRegistered), (true, .notFound):
            return setupFinished && !registeredBefore ? .register : .nothing
        case (false, .enabled), (false, .requiresApproval):
            return .unregister
        default:
            return .nothing
        }
    }

    /// The setting still says on, Wisp registered it once, and macOS no longer has it: the user took it out.
    public static func removedByUser(wanted: Bool, status: LoginItemStatus, registeredBefore: Bool) -> Bool {
        wanted && registeredBefore && (status == .notRegistered || status == .notFound)
    }

    /// What the Ajustes switch shows: macOS's answer, not the saved wish.
    public static func isOn(_ status: LoginItemStatus) -> Bool {
        status == .enabled || status == .requiresApproval
    }
}
