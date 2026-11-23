import Foundation

/// The app's one identity: bundle id, defaults domain, keychain services, log subsystem and launchd label all derive from it.
public enum AppIdentity {
    public static let bundleID = "ai.wisp.app"
    /// The user's Telegram bot job, the label `wisp setup telegram` installs.
    public static let botLabel = "ai.wisp.bot"
    public static let spotifyKeychainService = "\(bundleID).spotify"
    public static let webhookKeychainService = "\(bundleID).webhook"
    public static let googleKeychainService = "\(bundleID).google"

    /// Builds before `ai.wisp.app` used the developer's own reverse-DNS prefix, `com.<login>.wisp`. Only that machine
    /// has data under it, so for anyone else the old domain is simply empty and the migration does nothing.
    public static func legacyBundleID(login: String) -> String { "com.\(login.lowercased()).wisp" }

    public static func legacySpotifyKeychainService(login: String) -> String { "\(legacyBundleID(login: login)).spotify" }

    /// Copy the old defaults only into an untouched new domain, so a second launch never overwrites what the app wrote since.
    public static func shouldCopyDefaults(old: [String: Any]?, new: [String: Any]?) -> Bool {
        (new ?? [:]).isEmpty && !(old ?? [:]).isEmpty
    }

    /// Copy the old keychain item only when the new service has none; the old item is never deleted.
    public static func shouldCopyKeychainItem(oldExists: Bool, newExists: Bool) -> Bool {
        oldExists && !newExists
    }
}
