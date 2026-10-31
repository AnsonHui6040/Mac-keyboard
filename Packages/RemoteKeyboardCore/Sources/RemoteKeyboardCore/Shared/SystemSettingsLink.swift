import Foundation

/// The macOS System Settings pages the Receiver needs the user to open by hand.
public enum SystemSettingsLink: CaseIterable, Sendable {
    case accessibility, bluetoothPrivacy, loginItems

    public var urlString: String {
        switch self {
        case .accessibility: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .bluetoothPrivacy: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
        case .loginItems: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        }
    }
}
