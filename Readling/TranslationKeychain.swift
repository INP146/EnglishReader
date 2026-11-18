import Foundation
import Security

/// API keys for user-configured translation endpoints, one generic password per
/// endpoint UUID. Kept on this device only: not synced through iCloud Keychain,
/// not included in backups.
struct TranslationKeychain: Sendable {
    var service: String

    static let shared = TranslationKeychain(service: "com.inp146.readling.translation")

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    func key(account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setKey(_ key: String, account: String) throws {
        let data = Data(key.utf8)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(account) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(account).merging(update) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func deleteKey(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }

    func key(for endpointID: UUID) -> String? { key(account: endpointID.uuidString) }
    func setKey(_ key: String, for endpointID: UUID) throws { try setKey(key, account: endpointID.uuidString) }
    func deleteKey(for endpointID: UUID) throws { try deleteKey(account: endpointID.uuidString) }
}

struct KeychainError: LocalizedError {
    var status: OSStatus
    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? ""
        return String(localized: "无法保存到钥匙串（\(status)）。\(message)")
    }
}
