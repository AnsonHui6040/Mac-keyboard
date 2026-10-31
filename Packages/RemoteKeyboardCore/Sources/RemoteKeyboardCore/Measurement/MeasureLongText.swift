#if DEBUG
import CryptoKit
import Foundation

/// The 3,000-character text of the T07 check and of M5, M6-L and M7, and the Mac's check that it arrived whole: length and
/// SHA-256 only, the text itself is never logged.
public enum MeasureLongText {
    /// 3,000 characters in one `TEXT` (6,000 UTF-8 bytes).
    public static let text = String(repeating: "一二三四五六七八九十ABCDEFGHIJ", count: 150)
    public static let utf8Length = text.utf8.count
    public static let sha256Hex = sha256Hex(of: text)
    /// A text of at least this many UTF-8 bytes is compared against the long text, so a damaged copy is reported.
    public static let candidateMinimumUtf8 = 1_000

    public enum Check: Equatable, Sendable { case match, mismatch }

    public static func sha256Hex(of string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func isCandidate(_ string: String) -> Bool { string.utf8.count >= candidateMinimumUtf8 }

    public static func check(_ string: String) -> Check {
        string.utf8.count == utf8Length && sha256Hex(of: string) == sha256Hex ? .match : .mismatch
    }
}

/// Which connection latency the measurement asks for before it starts (`RKMEAS_LATENCY`). CoreBluetooth has no way to read
/// the interval that came out of it, so a result only ever says what was requested.
public enum MeasureLatencyPreference: Equatable, Sendable {
    case low, medium, none

    public static let `default` = MeasureLatencyPreference.low
    /// Time between the request and the start of the run.
    public static let settleSeconds = 2
    /// Length of the stretch of traffic before the request and of the one after the settling, for the arrival-interval evidence.
    public static let evidenceWindowSeconds = 5

    public init(environmentValue: String?) {
        switch environmentValue?.lowercased() {
        case "low": self = .low
        case "medium": self = .medium
        case "none": self = .none
        default: self = Self.default
        }
    }

    public var name: String {
        switch self {
        case .low: "low"
        case .medium: "medium"
        case .none: "none"
        }
    }

    public var isRequested: Bool { self != .none }
}
#endif
