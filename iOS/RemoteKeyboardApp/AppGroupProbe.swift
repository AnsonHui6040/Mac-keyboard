import Foundation
import RemoteKeyboardCore

enum AppGroupProbe {
    static let suiteName = AppGroup.identifier
    static let key = "probe"

    /// Stores the current time in the shared App Group defaults.
    /// Returns false when the suite is unavailable.
    @discardableResult
    static func write(now: Date = Date()) -> Bool {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return false }
        defaults.set(now.timeIntervalSince1970, forKey: key)
        return true
    }
}
