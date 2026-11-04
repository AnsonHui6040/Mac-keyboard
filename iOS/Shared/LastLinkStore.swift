import Foundation
import RemoteKeyboardCore

/// The last link result in the App Group. The Extension writes it, the host App reads it for the setup checklist and
/// clears it when the pairing changes. A failed write only leaves the checklist as it was; it holds no text.
enum LastLinkStore {
    /// Called by the Extension; does nothing without Full Access.
    static func record(_ result: LastLinkResult, hasFullAccess: Bool) {
        guard hasFullAccess else { return }
        let defaults = UserDefaults(suiteName: AppGroup.identifier)
        defaults?.set(result.rawValue, forKey: AppGroup.Key.lastLink)
        defaults?.set(Date().timeIntervalSince1970, forKey: AppGroup.Key.lastLinkAt)
    }

    static var current: LastLinkResult? {
        let defaults = UserDefaults(suiteName: AppGroup.identifier)
        return LastLinkResult.current(
            raw: defaults?.string(forKey: AppGroup.Key.lastLink),
            recordedAt: defaults?.object(forKey: AppGroup.Key.lastLinkAt) as? Double,
            now: Date().timeIntervalSince1970)
    }

    /// The old result no longer applies after a new pairing or 解除配對.
    static func clear() {
        UserDefaults(suiteName: AppGroup.identifier)?.removeObject(forKey: AppGroup.Key.lastLink)
    }
}
