import Foundation
import Security

nonisolated enum KeychainHelper {
    private static let service = "com.localcut.studio.publish"

    @discardableResult
    static func save(key: String, data: String) -> Bool {
        guard let valueData = data.data(using: .utf8) else { return false }
        // Remove any prior item from both stores so accessibility attributes are never left stale.
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: valueData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            // On macOS, kSecAttrAccessible only applies in the data-protection keychain.
            kSecUseDataProtectionKeychain as String: true
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    static func load(key: String) -> String? {
        if let value = copyMatching(key: key, useDataProtectionKeychain: true) {
            return value
        }
        // Legacy file-based items (pre-ThisDeviceOnly / pre-data-protection) still load,
        // then migrate into the device-bound data-protection keychain.
        guard let legacy = copyMatching(key: key, useDataProtectionKeychain: false) else {
            return nil
        }
        _ = save(key: key, data: legacy)
        return legacy
    }

    @discardableResult
    static func delete(key: String) -> Bool {
        let protected = deleteMatching(key: key, useDataProtectionKeychain: true)
        let legacy = deleteMatching(key: key, useDataProtectionKeychain: false)
        return protected || legacy
    }

    private static func copyMatching(key: String, useDataProtectionKeychain: Bool) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else { return nil }
        return string
    }

    private static func deleteMatching(key: String, useDataProtectionKeychain: Bool) -> Bool {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if useDataProtectionKeychain {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
