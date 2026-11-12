import Foundation
import RemoteKeyboardCore
import UIKit

/// This iPhone as a pairing partner sees it (docs/protocol/v4.md §4): a random 16-byte `phoneId` made the first time it is
/// asked for and kept in the App Group, the device name as `phoneName`, and the platform `ios`.
enum PhoneIdentityStore {
    static let phoneIdKey = "rk.phoneId.v4"
    /// Used when the device name is empty.
    static let defaultName = "iPhone"

    /// The identity to send in `pairReveal`. The name is read again each time, cut to 32 UTF-8 bytes on a Unicode scalar
    /// boundary, and replaced by the default when nothing is left of it.
    @MainActor
    static func load() -> PhoneIdentity {
        let defaults = UserDefaults(suiteName: AppGroup.identifier)
        let id: Data
        if let stored = defaults?.data(forKey: phoneIdKey), stored.count == IdentityName.idLength {
            id = stored
        } else {
            id = Data((0..<IdentityName.idLength).map { _ in UInt8.random(in: 0...255) })
            defaults?.set(id, forKey: phoneIdKey)
        }
        let name = IdentityName.clamp(UIDevice.current.name)
        return PhoneIdentity(id: id, name: name.isEmpty ? defaultName : name, platform: .ios)
    }
}
