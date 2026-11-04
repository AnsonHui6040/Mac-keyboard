import Foundation
import RemoteKeyboardCore

/// A `Bool` in the App Group: the keyboard has appeared once with 「允許完整取用」 on. The Extension writes it, the host App
/// reads it for the setup checklist. A failed write only leaves the checklist row unticked.
enum KeyboardReadyMarker {
    /// Called by the Extension when it appears; does nothing without Full Access.
    static func markIfReady(hasFullAccess: Bool) {
        guard hasFullAccess else { return }
        UserDefaults(suiteName: AppGroup.identifier)?.set(true, forKey: AppGroup.Key.keyboardReady)
    }

    static var isReady: Bool {
        UserDefaults(suiteName: AppGroup.identifier)?.bool(forKey: AppGroup.Key.keyboardReady) ?? false
    }
}
