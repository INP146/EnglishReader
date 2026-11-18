import Foundation
import Security

/// API keys for online translation engines, one generic password per engine.
/// Kept on this device only: not synced through iCloud Keychain, not in backups.
struct TranslationKeychain: Sendable {
    var service: String

    static let shared = TranslationKeychain(service: "com.inp146.readling.translation")

    private func query(_ engine: TranslationEngineID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: engine.rawValue]
    }

    func key(for engine: TranslationEngineID) -> String? {
        var query = query(engine)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setKey(_ key: String, for engine: TranslationEngineID) throws {
        let data = Data(key.utf8)
        let update: [String: Any] = [kSecValueData as String: data,
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query(engine) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(engine).merging(update) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    func deleteKey(for engine: TranslationEngineID) throws {
        let status = SecItemDelete(query(engine) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

struct KeychainError: LocalizedError {
    var status: OSStatus
    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? ""
        return String(localized: "无法保存到钥匙串（\(status)）。\(message)")
    }
}
