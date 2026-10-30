/// Which parts of the keyboard's top area are visible. Pure, so the table can be tested without UIKit.
///
/// Row 1 (mode toggle, status, transmit toggle) and the candidate row (blank until the Chinese pages) are always
/// there; the draft row is the optional one. So the area is two or three rows high.
public struct TopAreaState: Equatable, Sendable {
    public let showsStatus: Bool
    public let showsTransmitToggle: Bool
    public let showsDraftRow: Bool
    public let showsCandidateRow: Bool
    public let sendEnabled: Bool

    public init(mode: KeyboardMode, transmit: TransmitMode, ready: Bool, draftEmpty: Bool, hasNote: Bool) {
        switch mode {
        case .remote:
            showsStatus = true
            showsTransmitToggle = true
            showsDraftRow = transmit == .draft || !draftEmpty || !ready
            sendEnabled = ready && !draftEmpty
        case .local:
            showsStatus = hasNote
            showsTransmitToggle = false
            showsDraftRow = false
            sendEnabled = false
        }
        showsCandidateRow = true
    }

    public var visibleRowCount: Int { 1 + (showsDraftRow ? 1 : 0) + (showsCandidateRow ? 1 : 0) }
}

/// Sizes in points, chosen by the main agent for D17 (spec section 2).
public enum KeyboardMetrics {
    public static let topRowHeight: Double = 36
    public static let keyRowHeight: Double = 42
    public static let rowGap: Double = 12
    public static let keyRowCount = 4
    /// Space above the first key row and below the last one.
    public static let keyAreaVerticalInset: Double = 4
    /// Space left and right of the key rows, and between two keys in a row.
    public static let keyAreaSideInset: Double = 3
    public static let keyGap: Double = 6
    /// The handwriting page is this much taller than the English and symbols pages (user decision 2026-10-30).
    public static let handwritingExtraHeight: Double = 60

    public static var keyAreaHeight: Double {
        Double(keyRowCount) * keyRowHeight + Double(keyRowCount - 1) * rowGap + 2 * keyAreaVerticalInset
    }

    public static func height(visibleTopRows: Int) -> Double {
        Double(visibleTopRows) * topRowHeight + keyAreaHeight
    }

    /// Total keyboard height; the handwriting page adds `handwritingExtraHeight`.
    public static func height(visibleTopRows: Int, handwriting: Bool) -> Double {
        height(visibleTopRows: visibleTopRows) + (handwriting ? handwritingExtraHeight : 0)
    }
}
