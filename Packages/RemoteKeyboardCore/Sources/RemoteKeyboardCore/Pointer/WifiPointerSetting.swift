import Foundation

/// 「經 Wi-Fi 傳送游標」 (spec W11): a `Bool` the host App writes into the App Group and the keyboard reads when it opens the
/// touchpad channel. Not set, or not a `Bool`, means on.
public enum WifiPointerSetting {
    public static let defaultValue = true

    public static func isEnabled(stored: Any?) -> Bool {
        (stored as? Bool) ?? defaultValue
    }
}
