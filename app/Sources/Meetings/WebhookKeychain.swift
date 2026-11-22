import Foundation
import Security
import WispCore

enum WebhookKeychain {
    enum Item: String {
        case url, secret
    }

    static func load(_ item: Item) -> String? {
        var query = base(item)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String, for item: Item) -> Bool {
        guard !value.isEmpty else {
            SecItemDelete(base(item) as CFDictionary)
            return true
        }
        let data = Data(value.utf8)
        let update = SecItemUpdate(base(item) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var added = base(item)
        added[kSecValueData as String] = data
        added[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        added[kSecAttrLabel as String] = "Wisp — webhook das reuniões"
        return SecItemAdd(added as CFDictionary, nil) == errSecSuccess
    }

    static func ensureSecret() -> String? {
        if let existing = load(.secret) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let secret = bytes.map { String(format: "%02x", $0) }.joined()
        return save(secret, for: .secret) ? secret : nil
    }

    private static func base(_ item: Item) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppIdentity.webhookKeychainService,
            kSecAttrAccount as String: item.rawValue,
        ]
    }
}
