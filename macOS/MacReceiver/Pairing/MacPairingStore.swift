import CryptoKit
import Foundation
import Security

/// Where the Mac keeps the one pair key it holds.
protocol PairKeyStoring: AnyObject {
    func load() -> SymmetricKey?
    func save(_ key: SymmetricKey) throws
    /// Removing a key that is not there is not an error.
    func delete()
}

enum PairKeyStoreError: Error, Equatable {
    case keychain(OSStatus)
}

/// The pair key in the macOS Keychain: one generic password item, service `com.ansonhui.remotekeyboard.pairing`
/// (the iPhone uses the same service name), account `pairKey`. The key is never logged.
final class MacPairingStore: PairKeyStoring {
    static let service = "com.ansonhui.remotekeyboard.pairing"
    static let account = "pairKey"

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account
        ]
    }

    func load() -> SymmetricKey? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    func save(_ key: SymmetricKey) throws {
        delete()
        var query = baseQuery()
        query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw PairKeyStoreError.keychain(status) }
    }

    func delete() {
        _ = SecItemDelete(baseQuery() as CFDictionary)
    }
}
