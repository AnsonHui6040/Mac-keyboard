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

    // MARK: Strip content (hand-computed frames; the row's content uses no Auto Layout)

    /// A frame inside the scrolling strip.
    public struct StripRect: Equatable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public struct Strip: Equatable, Sendable {
        /// The input code label; nil when there is no code.
        public let composing: StripRect?
        public let candidates: [StripRect]
        /// Width of the scroll view's content.
        public let contentWidth: Double
    }

    public static let stripSideMargin: Double = 6
    public static let stripVerticalMargin: Double = 3
    public static let stripItemSpacing: Double = 4
    public static let candidateInset: Double = 10
    public static let candidateMinWidth: Double = 40
    public static let composingMinWidth: Double = 44

    /// Frames for the code label and the candidate buttons, from their measured text widths. Widths are rounded up to
    /// whole points so text is not clipped.
    public static func strip(composingTextWidth: Double?, candidateTextWidths: [Double], height: Double) -> Strip {
        let itemHeight = max(0, height - 2 * stripVerticalMargin)
        var x = stripSideMargin
        var composing: StripRect?
        var candidates: [StripRect] = []
        candidates.reserveCapacity(candidateTextWidths.count)
        var count = 0
        if let textWidth = composingTextWidth {
            let width = max(composingMinWidth, textWidth.rounded(.up))
            composing = StripRect(x: x, y: stripVerticalMargin, width: width, height: itemHeight)
            x += width
            count += 1
        }
        for textWidth in candidateTextWidths {
            if count > 0 { x += stripItemSpacing }
            let width = max(candidateMinWidth, textWidth.rounded(.up) + 2 * candidateInset)
            candidates.append(StripRect(x: x, y: stripVerticalMargin, width: width, height: itemHeight))
            x += width
            count += 1
        }
        return Strip(composing: composing, candidates: candidates, contentWidth: count == 0 ? 0 : x + stripSideMargin)
    }
}
