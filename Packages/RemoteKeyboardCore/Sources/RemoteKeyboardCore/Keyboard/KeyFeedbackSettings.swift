import Foundation

/// Which key feedback is really on: the user's two switches (App Group, default on) and Full Access. Pure, so the rule
/// is tested without UIKit.
public struct KeyFeedbackSettings: Equatable, Sendable {
    /// The click sound. It follows the iPhone silent switch and the system keyboard feedback setting, and does not need
    /// Full Access.
    public let sound: Bool
    /// The light tap. iOS only allows it with Full Access.
    public let haptics: Bool

    /// `storedSound` and `storedHaptics` are the raw App Group values. Not set, or not a `Bool`, means on.
    public init(storedSound: Any?, storedHaptics: Any?, hasFullAccess: Bool) {
        sound = (storedSound as? Bool) ?? true
        haptics = ((storedHaptics as? Bool) ?? true) && hasFullAccess
    }
}
