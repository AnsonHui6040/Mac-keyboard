import CryptoKit
import Foundation
import RemoteKeyboardCore
import Security

/// The one pair key this iPhone holds, as a Keychain generic password shared by the host App (which writes it after a
/// pairing) and the keyboard Extension (which reads it on every connection; this needs Full Access).
///
/// The access group is the App Group identifier and nothing else (`AppGroup.keychainAccessGroup`). The key is never
/// logged.
enum PairingStore {
    static let service = "com.ansonhui.remotekeyboard.pairing"
    static let account = "pairKey"
    private static let keyLength = 32

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: AppGroup.keychainAccessGroup
        ]
    }

    /// Replaces the stored key. `errSecSuccess` when stored.
    static func savePairKey(_ key: SymmetricKey) -> OSStatus {
        _ = SecItemDelete(baseQuery() as CFDictionary)
        var query = baseQuery()
        query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    /// The stored key, or `nil` when there is none (or it cannot be read, as in an Extension without Full Access).
    static func loadPairKey() -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == keyLength else { return nil }
        return SymmetricKey(data: data)
    }

    /// 「解除配對」. Deleting a key that is not there is fine.
    @discardableResult
    static func deletePairKey() -> OSStatus {
        SecItemDelete(baseQuery() as CFDictionary)
    }
}
