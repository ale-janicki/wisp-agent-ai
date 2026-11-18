import Foundation
import os
import WispCore

/// One-time move from the previous bundle id: its defaults domain and its Spotify keychain item are copied, never deleted.
/// Settings, conversations and setup state live in `Application Support/Wisp`, which does not depend on the bundle id.
enum IdentityMigration {
    private static let log = Logger(subsystem: AppIdentity.bundleID, category: "migration")

    static func run(login: String = NSUserName()) {
        let legacy = AppIdentity.legacyBundleID(login: login)
        let defaults = UserDefaults.standard
        let old = defaults.persistentDomain(forName: legacy)
        if AppIdentity.shouldCopyDefaults(old: old, new: defaults.persistentDomain(forName: AppIdentity.bundleID)), let old {
            defaults.setPersistentDomain(old, forName: AppIdentity.bundleID)
            log.info("copied \(old.count, privacy: .public) defaults keys from the previous bundle id")
        }
        SpotifyKeychain.adoptLegacyItem(from: AppIdentity.legacySpotifyKeychainService(login: login))
    }
}
