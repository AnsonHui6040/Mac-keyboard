import Foundation
import RemoteKeyboardCore

/// The key layout files (`ime/layouts/*.json`) the keyboard and the host App's preview bundle as the `layouts` folder.
enum BundledLayouts {
    /// Reads and validates `layouts/<id>.json` from `bundle`; nil when it is missing or invalid.
    static func load(_ id: String, bundle: Bundle) -> KeyboardLayout? {
        guard
            let url = bundle.url(forResource: id, withExtension: "json", subdirectory: "layouts"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return try? KeyboardLayout.decode(data)
    }
}
