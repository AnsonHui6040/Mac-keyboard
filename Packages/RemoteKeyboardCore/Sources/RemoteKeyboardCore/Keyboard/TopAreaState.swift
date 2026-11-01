/// Which parts of the keyboard's top area are visible. Pure, so the table can be tested without UIKit.
///
/// Row 1 (mode toggle, status, touchpad key, dismiss key, transmit toggle) is always there. The draft row and the
/// candidate row (Quick page only) are optional, so the area is one to three rows high.
public struct TopAreaState: Equatable, Sendable {
    public let showsStatus: Bool
    public let showsTransmitToggle: Bool
    /// The 觸控板 key: Remote mode only (usable only while connected; that is the view's state, not this one).
    public let showsTrackpadKey: Bool
    public let showsDraftRow: Bool
    public let showsCandidateRow: Bool
    public let sendEnabled: Bool

    /// - Parameter showsCandidates: the Quick page, the only page whose candidates sit in the top area.
    public init(
        mode: KeyboardMode, transmit: TransmitMode, ready: Bool, draftEmpty: Bool, hasNote: Bool, showsCandidates: Bool
    ) {
        switch mode {
        case .remote:
            showsStatus = true
            showsTransmitToggle = true
            showsTrackpadKey = true
            showsDraftRow = transmit == .draft || !draftEmpty || !ready
            sendEnabled = ready && !draftEmpty
        case .local:
            showsStatus = hasNote
            showsTransmitToggle = false
            showsTrackpadKey = false
            showsDraftRow = false
            sendEnabled = false
        }
        showsCandidateRow = showsCandidates
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
