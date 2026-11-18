import Foundation
import Security
import WispCore

enum SpotifyKeychain {
    static let service = AppIdentity.spotifyKeychainService
    private static let account = "session"

    enum Failure: Error {
        case status(OSStatus)
    }

    static func load() -> SpotifyToken? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(SpotifyToken.self, from: data)
    }

    static func save(_ token: SpotifyToken) throws {
        let data = try JSONEncoder().encode(token)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure.status(update) }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "Wisp — Spotify"
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure.status(added) }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    /// Copies the session saved under the previous bundle id's service, once, when this service has none.
    /// The old item stays where it is.
    static func adoptLegacyItem(from legacyService: String) {
        var probe = query(service)
        probe[kSecMatchLimit as String] = kSecMatchLimitOne
        let newExists = SecItemCopyMatching(probe as CFDictionary, nil) == errSecSuccess
        var old = query(legacyService)
        old[kSecReturnData as String] = true
        old[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let oldExists = SecItemCopyMatching(old as CFDictionary, &result) == errSecSuccess
        guard AppIdentity.shouldCopyKeychainItem(oldExists: oldExists, newExists: newExists), let data = result as? Data else { return }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = "Wisp — Spotify"
        SecItemAdd(item as CFDictionary, nil)
    }

    private static var baseQuery: [String: Any] { query(service) }

    private static func query(_ service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
