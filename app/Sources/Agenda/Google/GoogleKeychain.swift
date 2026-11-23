import Foundation
import Security
import WispCore

/// Keychain items for the Google Agenda integration: the user's OAuth client JSON, and one token per account keyed by its email.
enum GoogleKeychain {
    private static let clientAccount = "client"
    private static let tokenPrefix = "token:"

    #if DEBUG || WISP_PERF
    static let disabled = ProcessInfo.processInfo.arguments.contains("-WispNoKeychain")
    #else
    static let disabled = false
    #endif

    static func loadClient() -> GoogleClient? {
        guard let data = load(clientAccount) else { return nil }
        return try? GoogleClient.parse(data)
    }

    @discardableResult
    static func saveClient(_ client: GoogleClient) -> Bool {
        save(client.serialized(), account: clientAccount, label: "Wisp — Google Agenda (cliente OAuth)")
    }

    static func deleteClient() {
        delete(clientAccount)
    }

    static func emails() -> [String] {
        guard !disabled else { return [] }
        var query = base(nil)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let rows = result as? [[String: Any]] else { return [] }
        return rows.compactMap { ($0[kSecAttrAccount as String] as? String)?.dropPrefix(tokenPrefix) }.sorted()
    }

    static func loadToken(_ email: String) -> GoogleToken? {
        guard let data = load(tokenPrefix + email.lowercased()) else { return nil }
        return try? JSONDecoder().decode(GoogleToken.self, from: data)
    }

    @discardableResult
    static func saveToken(_ token: GoogleToken) -> Bool {
        guard let data = try? JSONEncoder().encode(token) else { return false }
        return save(data, account: tokenPrefix + token.email.lowercased(), label: "Wisp — Google Agenda (\(token.email))")
    }

    static func deleteToken(_ email: String) {
        delete(tokenPrefix + email.lowercased())
    }

    // MARK: Generic items

    private static func load(_ account: String) -> Data? {
        guard !disabled else { return nil }
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    private static func save(_ data: Data, account: String, label: String) -> Bool {
        guard !disabled else { return false }
        let update = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = base(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecAttrLabel as String] = label
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private static func delete(_ account: String) {
        guard !disabled else { return }
        SecItemDelete(base(account) as CFDictionary)
    }

    private static func base(_ account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppIdentity.googleKeychainService,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
