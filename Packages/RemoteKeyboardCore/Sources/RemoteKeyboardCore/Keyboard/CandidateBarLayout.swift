/// Geometry of the candidate row when it carries the delete key at its right end (Chinese page only).
public enum CandidateBarLayout {
    /// The candidate row is as tall as every other top row, whatever the number of top rows.
    public static let rowHeight: Double = KeyboardMetrics.topRowHeight
    public static let backspaceWidth: Double = 48
    /// Space above and below the delete key.
    public static let verticalInset: Double = 3
    /// Space between the delete key and the right edge of the row; matches the draft row's margin.
    public static let trailingInset: Double = 6
    /// Space between the scrolling candidates and the delete key.
    public static let gap: Double = KeyboardMetrics.keyGap

    public static var backspaceHeight: Double { rowHeight - 2 * verticalInset }

    /// Horizontal extent of the delete key.
    public struct BackspaceFrame: Equatable, Sendable {
        public let x: Double
        public let width: Double
    }

    public struct Frames: Equatable, Sendable {
        /// Width of the scrolling candidate strip, which starts at x = 0.
        public let scrollWidth: Double
        /// The delete key; nil when the row has no delete key.
        public let backspace: BackspaceFrame?
    }

    public static func frames(totalWidth: Double, showsBackspace: Bool) -> Frames {
        guard showsBackspace else { return Frames(scrollWidth: max(0, totalWidth), backspace: nil) }
        let x = totalWidth - trailingInset - backspaceWidth
        return Frames(scrollWidth: max(0, x - gap), backspace: BackspaceFrame(x: x, width: backspaceWidth))
    }
}
