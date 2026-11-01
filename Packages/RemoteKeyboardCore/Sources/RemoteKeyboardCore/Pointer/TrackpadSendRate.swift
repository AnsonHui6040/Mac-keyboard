import Foundation

/// How many cursor packets per second the touchpad page may send at most (the 「傳輸次數」 bar). Pure value logic: the
/// extension stores the number, this type keeps it inside 20…120 on a grid of 10, plus one more step after 120, 「自動」
/// (stored as 0), and turns it into the rate of the `PointerSender` and the frame rate the display link asks for.
///
/// 自動 sends whenever the radio has room and there is movement, so the radio's connection events set the pace. It is the
/// default. It is stored under a new key (`AppGroup.Key.trackpadSendRate`, `.v2`) so that a rate chosen with the old bar, which
/// had 60 as its default, does not keep new users off it; the old key is no longer read.
public enum TrackpadSendRate {
    /// The stored and in-memory value of 「自動」.
    public static let automatic = 0
    public static let defaultValue = automatic
    public static let minimum = 20
    public static let maximum = 120
    public static let step = 10
    public static let all: [Int] = Array(stride(from: minimum, through: maximum, by: step))

    public static func isAutomatic(_ value: Int) -> Bool { value == automatic }

    /// Snaps to the grid of 10 and clamps to the range; 0 is 自動 and stays.
    public static func clamped(_ value: Int) -> Int {
        if value == automatic { return automatic }
        let snapped = (Double(min(max(value, minimum), maximum)) / Double(step)).rounded() * Double(step)
        return min(max(Int(snapped), minimum), maximum)
    }

    /// A raw stored value: an integer or a finite number is clamped; anything else (nothing, text, a `Bool`, NaN) is the default.
    public static func clamped(_ stored: Any?) -> Int {
        if let number = stored as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let d = number.doubleValue
            guard d.isFinite else { return defaultValue }
            return clamped(Int(min(max(d.rounded(), -1e6), 1e6)))
        }
        return defaultValue
    }

    /// One button press (`steps` of +1 or -1) from `value`: 120 and + is 自動, 自動 and − is 120, 自動 and + stays.
    public static func stepped(_ value: Int, by steps: Int) -> Int {
        let current = clamped(value)
        let position = isAutomatic(current) ? maximum + step : current
        let next = min(max(position + steps * step, minimum), maximum + step)
        return next > maximum ? automatic : next
    }

    /// The value as shown: 「60 次/秒」.
    public static func displayText(_ value: Int) -> String {
        isAutomatic(clamped(value)) ? "自動" : "\(clamped(value)) 次/秒"
    }

    /// 1/rate in microseconds.
    /// 自動 counts as 120.
    public static func intervalMicros(_ rate: Int) -> UInt64 {
        let value = isAutomatic(clamped(rate)) ? maximum : clamped(rate)
        return UInt64((1_000_000.0 / Double(value)).rounded())
    }

    /// The frame-rate range for the display link. Up to 60 it asks for 60; above that, and for 自動, it asks for 120 (90 is not a rate a
    /// ProMotion screen offers, so the system would pick for itself) and the sender's token bucket takes the rate out of it.
    public static func frameRate(for rate: Int) -> (minimum: Float, maximum: Float, preferred: Float) {
        isAutomatic(clamped(rate)) || clamped(rate) > 60 ? (80, 120, 120) : (60, 120, 60)
    }
}
