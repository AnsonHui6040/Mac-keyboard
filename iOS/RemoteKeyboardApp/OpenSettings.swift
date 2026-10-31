import UIKit

/// Opens this app's page in the iPhone Settings app (Keyboards and Bluetooth switches live there).
enum OpenSettings {
    @MainActor
    static func open() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}
