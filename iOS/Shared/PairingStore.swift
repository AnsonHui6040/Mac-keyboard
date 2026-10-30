import Foundation
import Security

/// Thin Keychain wrapper (generic password) shared by the host App and the keyboard Extension.
/// Items are stored per access group so the same code can probe more than one candidate group.
enum PairingStore {
    static let service = "com.ansonhui.remotekeyboard.pairing"

    /// The App Group identifier used directly as a keychain access group.
    static let primaryAccessGroup = "group.com.ansonhui.remotekeyboard"
    private static let fallbackSuffix = "com.ansonhui.remotekeyboard.shared"

    /// `<TeamPrefix>com.ansonhui.remotekeyboard.shared`. The team prefix (it already ends with a dot) is read from
    /// the `AppIdentifierPrefix` key that both Info.plists carry. Nil when the key is missing or unexpanded.
    static var fallbackAccessGroup: String? {
        guard let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String,
              !prefix.isEmpty, !prefix.contains("$") else { return nil }
        return prefix + fallbackSuffix
    }

    private static func baseQuery(account: String, accessGroup: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: accessGroup
        ]
    }

    /// Stores `data`, replacing an existing item with the same account in the same group.
    static func save(_ data: Data, account: String, accessGroup: String) -> OSStatus {
        _ = SecItemDelete(baseQuery(account: account, accessGroup: accessGroup) as CFDictionary)
        var query = baseQuery(account: account, accessGroup: accessGroup)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(query as CFDictionary, nil)
    }

    /// Returns the stored data, or nil with the failing status (`errSecItemNotFound` when absent).
    static func load(account: String, accessGroup: String) -> (Data?, OSStatus) {
        var query = baseQuery(account: account, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return (nil, status) }
        return (result as? Data, status)
    }

    static func delete(account: String, accessGroup: String) -> OSStatus {
        SecItemDelete(baseQuery(account: account, accessGroup: accessGroup) as CFDictionary)
    }

    // MARK: Step 0 probe

    static let probeAccount = "probe"
    /// Status reported when the fallback group cannot be resolved (no team prefix in Info.plist).
    static let noFallbackGroupStatus: OSStatus = -1

    /// Writes the current time under `probe` into both candidate groups. Returns (primary, fallback) statuses.
    static func writeProbe(now: Date = Date()) -> (primary: OSStatus, fallback: OSStatus) {
        let data = Data(String(now.timeIntervalSince1970).utf8)
        let primary = save(data, account: probeAccount, accessGroup: primaryAccessGroup)
        let fallback = fallbackAccessGroup.map { save(data, account: probeAccount, accessGroup: $0) }
            ?? noFallbackGroupStatus
        return (primary, fallback)
    }

    /// Reads the probe from one group and renders `OK`, `NIL` (not found) or the numeric OSStatus.
    static func probeLabel(accessGroup: String?) -> String {
        guard let accessGroup else { return String(noFallbackGroupStatus) }
        let (data, status) = load(account: probeAccount, accessGroup: accessGroup)
        if data != nil, status == errSecSuccess { return "OK" }
        if status == errSecItemNotFound { return "NIL" }
        return String(status)
    }

    /// `主 / 備` status for the keyboard's probe label. Reads each group once and never throws.
    static func probeSummary() -> String {
        "KC: \(probeLabel(accessGroup: primaryAccessGroup)) / \(probeLabel(accessGroup: fallbackAccessGroup))"
    }
}
