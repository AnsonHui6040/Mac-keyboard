import CryptoKit
import Foundation
import RemoteKeyboardCore
import Security

/// What this iPhone knows about its paired hosts (docs/protocol/v4.md §4, design §6).
///
/// - The list of hosts (id, name, platform) and which one is current live in the App Group, as one JSON value under
///   `rk.hosts.v4`. It holds no secret.
/// - Each host's pair key is its own Keychain generic password, account `pairKey.<hostId as lowercase hex>`. The host App
///   writes it after a pairing and the keyboard Extension reads the current host's key on every connection (this needs Full
///   Access). The access group is the App Group identifier and nothing else (`AppGroup.keychainAccessGroup`).
///
/// A key is never logged.
enum PairingStore {
    static let service = "com.ansonhui.remotekeyboard.pairing"
    /// The account of the single key v3 stored. It cannot be used any more (the key derivation changed), and is deleted.
    static let legacyAccount = "pairKey"
    static let hostsKey = "rk.hosts.v4"
    private static let keyLength = 32

    static func account(hostId: Data) -> String {
        "pairKey." + hostId.map { String(format: "%02x", $0) }.joined()
    }

    private static func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: AppGroup.keychainAccessGroup
        ]
    }

    // MARK: Host list (App Group)

    /// The stored hosts and the current one; empty when nothing is stored or it cannot be read (an Extension without Full
    /// Access, or a value that does not decode).
    static func loadHosts() -> HostSelection {
        guard let data = UserDefaults(suiteName: AppGroup.identifier)?.data(forKey: hostsKey),
              let selection = try? JSONDecoder().decode(HostSelection.self, from: data) else { return HostSelection() }
        return selection
    }

    static func saveHosts(_ selection: HostSelection) {
        guard let data = try? JSONEncoder().encode(selection) else { return }
        UserDefaults(suiteName: AppGroup.identifier)?.set(data, forKey: hostsKey)
    }

    // MARK: Pair keys (Keychain)

    /// Replaces the stored key of `hostId`. `errSecSuccess` when stored.
    static func savePairKey(_ key: SymmetricKey, hostId: Data) -> OSStatus {
        let account = account(hostId: hostId)
        _ = SecItemDelete(baseQuery(account: account) as CFDictionary)
        var query = baseQuery(account: account)
        query[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }

    /// The stored key of `hostId`, or `nil` when there is none (or it cannot be read, as in an Extension without Full Access).
    static func loadPairKey(hostId: Data) -> SymmetricKey? {
        var query = baseQuery(account: account(hostId: hostId))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, data.count == keyLength else { return nil }
        return SymmetricKey(data: data)
    }

    /// Removes the host from the list and its key from the Keychain. A host that is not there is fine.
    static func deleteHost(id: Data) {
        var selection = loadHosts()
        selection.remove(id: id)
        saveHosts(selection)
        SecItemDelete(baseQuery(account: account(hostId: id)) as CFDictionary)
    }

    /// Deletes the single v3 key. The App and the Extension each call this once when they start; with nothing stored it does
    /// nothing, and an Extension without Full Access cannot reach the item at all.
    static func removeLegacyKey() {
        SecItemDelete(baseQuery(account: legacyAccount) as CFDictionary)
    }

    // MARK: Whole-list state

    /// Whether any host is stored: what the setup checklist calls 「已配對」.
    static var hasHost: Bool { !loadHosts().hosts.isEmpty }
}

extension HostPlatform {
    /// How a host's platform is named on screen.
    var displayName: String {
        switch self {
        case .mac: "Mac"
        case .windows: "Windows"
        case .linux: "Linux"
        }
    }
}
