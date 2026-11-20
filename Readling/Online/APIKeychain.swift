import Foundation
import Security

/// API keys for user-configured online services, one generic password per
/// account under a service name. Kept on this device only: not synced through
/// iCloud Keychain, not included in backups.
struct APIKeychain: Sendable {
    var service: String

    /// Keys of AI endpoints, one account per endpoint UUID.
    static let ai = APIKeychain(service: "com.inp146.readling.ai")
    /// Keys of translation-only services such as DeepL, one account per service.
    static let translation = APIKeychain(service: "com.inp146.readling.translation")

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

    /// Applies an edit from a settings form: keep, replace (an empty value deletes), or delete.
    func apply(_ change: KeyChange, account: String) throws {
        switch change {
        case .unchanged: break
        case .set(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { try deleteKey(account: account) } else { try setKey(trimmed, account: account) }
        case .clear:
            try deleteKey(account: account)
        }
    }
}

/// What a settings form did to a saved key.
enum KeyChange: Equatable, Sendable {
    case unchanged
    case set(String)
    case clear
}

struct KeychainError: LocalizedError {
    var status: OSStatus
    var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? ""
        return String(localized: "无法保存到钥匙串（\(status)）。\(message)")
    }
}
