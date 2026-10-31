import Foundation

/// The cursor-movement multiplier of the touchpad page (a tuning aid). Pure value logic: the extension stores the number,
/// this type keeps it inside 0.2…3.0 on a 0.1 grid and scales a one-finger delta by it.
public enum TrackpadSensitivity {
    public static let defaultValue = 1.0
    public static let minimum = 0.2
    public static let maximum = 3.0
    public static let step = 0.1
    /// Where the value used to live: the extension's own standard defaults. Read once for the move to the App Group.
    public static let legacyDefaultsKey = "rk.trackpad.sensitivity"

    /// The stored value from the App Group (`rk.trackpadSensitivity`, written by the host App) or, when that is not a number,
    /// the old extension-only one; `migrated` says the old one was used, so the caller copies it over and drops it.
    public static func resolved(appGroup: Any?, legacy: Any?) -> (value: Double, migrated: Bool) {
        if let value = number(appGroup) { return (clamped(value), false) }
        if let value = number(legacy) { return (clamped(value), true) }
        return (defaultValue, false)
    }

    private static func number(_ stored: Any?) -> Double? {
        guard let n = stored as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    /// Snaps to the 0.1 grid and clamps to the range; `nil` and NaN give the default.
    public static func clamped(_ value: Double?) -> Double {
        guard let value, !value.isNaN else { return defaultValue }
        let tenths = (min(max(value, minimum), maximum) * 10).rounded()
        return min(max(tenths / 10, minimum), maximum)
    }

    /// One button press (`steps` of +1 or -1) from `value`, kept on the grid and inside the range.
    public static func stepped(_ value: Double, by steps: Int) -> Double {
        let tenths = (clamped(value) * 10).rounded() + Double(steps)
        return clamped(tenths / 10)
    }

    /// The value as shown, one decimal ("1.0").
    public static func displayText(_ value: Double) -> String {
        String(format: "%.1f", clamped(value))
    }

    public static func scaled(dx: Double, dy: Double, by factor: Double) -> (dx: Double, dy: Double) {
        (dx * factor, dy * factor)
    }
}
