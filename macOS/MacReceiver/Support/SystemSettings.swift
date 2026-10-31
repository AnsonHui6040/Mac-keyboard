import AppKit
import RemoteKeyboardCore

/// Opens a System Settings page; the user still grants the permission themselves.
enum SystemSettings {
    @MainActor
    static func open(_ link: SystemSettingsLink) {
        guard let url = URL(string: link.urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
