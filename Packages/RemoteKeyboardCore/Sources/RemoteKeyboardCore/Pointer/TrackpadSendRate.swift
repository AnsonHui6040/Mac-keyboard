import Foundation

/// How many cursor packets per second the touchpad page may send at most (the 「傳輸次數」 bar). Pure value logic: the
/// extension stores the number, this type keeps it inside 20…120 on a grid of 10 and turns it into the pacing of the
/// `PointerSender` and the frame rate the display link asks for.
public enum TrackpadSendRate {
    public static let defaultValue = 60
    public static let minimum = 20
    public static let maximum = 120
    public static let step = 10
    public static let all: [Int] = Array(stride(from: minimum, through: maximum, by: step))

    /// Snaps to the grid of 10 and clamps to the range.
    public static func clamped(_ value: Int) -> Int {
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

    /// One button press (`steps` of +1 or -1) from `value`.
    public static func stepped(_ value: Int, by steps: Int) -> Int {
        clamped(clamped(value) + steps * step)
    }

    /// The value as shown: 「60 次/秒」.
    public static func displayText(_ value: Int) -> String {
        "\(clamped(value)) 次/秒"
    }

    /// 1/rate in microseconds.
    public static func intervalMicros(_ rate: Int) -> UInt64 {
        UInt64((1_000_000.0 / Double(clamped(rate))).rounded())
    }

    /// The smallest gap the sender keeps between two moves: 90% of 1/rate, so a display tick that arrives a little early is not
    /// skipped (which would halve the rate). At 60 this is the 15 ms the sender always used.
    public static func pacingMicros(_ rate: Int) -> UInt64 {
        UInt64((900_000.0 / Double(clamped(rate))).rounded())
    }

    /// The frame-rate range for the display link: never slower than the rate (and 60 at least), up to 120.
    public static func frameRate(for rate: Int) -> (minimum: Float, maximum: Float, preferred: Float) {
        let r = Float(clamped(rate))
        return (max(60, r), 120, max(60, r))
    }
}
