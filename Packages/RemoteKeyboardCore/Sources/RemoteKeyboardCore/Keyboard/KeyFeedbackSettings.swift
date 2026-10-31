import Foundation

/// Which key feedback is really on, and how strong: the user's two switches (App Group, default on), the two levels
/// (App Group, default 140% sound and 70% haptics) and Full Access. Pure, so the rule is tested without UIKit.
public struct KeyFeedbackSettings: Equatable, Sendable {
    public static let defaultSoundVolume = 1.4
    public static let soundVolumeRange: ClosedRange<Double> = 0...2
    public static let defaultHapticIntensity = 0.7
    public static let hapticIntensityRange: ClosedRange<Double> = 0...1
    /// The most the click is amplified beyond the file: +6 dB, the gain of volume 2.0.
    public static let maxGainDB: Float = 6.0206

    /// The click sound. It follows the iPhone silent switch and does not need Full Access when it is the system click.
    public let sound: Bool
    /// The tap. iOS only allows it with Full Access.
    public let haptics: Bool
    /// The sound level, 0 (silent) to 2 (200%). 1 is the file's own level.
    public let soundVolume: Double
    /// The tap strength, 0 (none) to 1.
    public let hapticIntensity: Double
    /// The keyboard plays its own click at `soundVolume`. Without Full Access it uses the system click instead.
    public let customSound: Bool

    /// `storedSound`, `storedHaptics`, `storedVolume` and `storedIntensity` are the raw App Group values. A switch that
    /// is not set, or not a `Bool`, means on. A level that is not a finite number means the default; one out of range
    /// is clamped.
    public init(
        storedSound: Any?, storedHaptics: Any?, storedVolume: Any? = nil, storedIntensity: Any? = nil,
        hasFullAccess: Bool
    ) {
        sound = (storedSound as? Bool) ?? true
        haptics = ((storedHaptics as? Bool) ?? true) && hasFullAccess
        soundVolume = Self.level(storedVolume, default: Self.defaultSoundVolume, range: Self.soundVolumeRange)
        hapticIntensity = Self.level(
            storedIntensity, default: Self.defaultHapticIntensity, range: Self.hapticIntensityRange)
        customSound = sound && hasFullAccess
    }

    /// Player node volume and EQ gain for this setting's `soundVolume`.
    public var soundOutput: (nodeVolume: Float, gainDB: Float) { Self.output(forVolume: soundVolume) }

    /// Up to 100% the node volume does the work; above that the node stays at 1 and the EQ's global gain adds
    /// `20·log10(volume)` dB, at most +6 dB. A volume that is not a number counts as silent.
    public static func output(forVolume volume: Double) -> (nodeVolume: Float, gainDB: Float) {
        guard !volume.isNaN else { return (0, 0) }
        let v = min(max(volume, 0), soundVolumeRange.upperBound)
        guard v > 1 else { return (Float(v), 0) }
        return (1, min(Float(20 * log10(v)), maxGainDB))
    }

    private static func level(_ stored: Any?, default fallback: Double, range: ClosedRange<Double>) -> Double {
        // `UserDefaults` hands numbers back as `NSNumber`; a `Bool` is not a level.
        guard let boxed = stored as? NSNumber, CFGetTypeID(boxed) != CFBooleanGetTypeID() else { return fallback }
        let number = boxed.doubleValue
        guard number.isFinite else { return fallback }
        return min(max(number, range.lowerBound), range.upperBound)
    }
}
