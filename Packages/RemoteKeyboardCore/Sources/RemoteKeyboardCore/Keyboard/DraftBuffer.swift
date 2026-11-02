/// The text typed in Remote mode that has not been sent yet. It lives in memory only and is never logged.
/// The cursor and the cap count `Character`s (grapheme clusters), so a family emoji is one position.
public struct DraftBuffer: Sendable, Equatable {
    public static let maxCharacters = 1_000
    /// A `.text` event stays well under the 2,000 byte mark so one message is always a handful of frames.
    public static let maxEventBytes = 2_000

    public private(set) var text: String
    public private(set) var cursor: Int

    public init() {
        text = ""
        cursor = 0
    }

    public var isEmpty: Bool { text.isEmpty }
    public var textBeforeCursor: String { String(text.prefix(cursor)) }
    public var textAfterCursor: String { String(text.dropFirst(cursor)) }

    /// Inserts at the cursor. Returns `false` and changes nothing if the result would pass `maxCharacters`.
    public mutating func insert(_ s: String) -> Bool {
        let before = textBeforeCursor + s
        let result = before + textAfterCursor
        guard result.count <= Self.maxCharacters else { return false }
        text = result
        cursor = before.count
        return true
    }

    /// Removes the character before the cursor.
    public mutating func deleteBackward() {
        guard cursor > 0 else { return }
        let before = String(textBeforeCursor.dropLast())
        text = before + textAfterCursor
        cursor = before.count
    }

    public mutating func moveLeft() {
        cursor = max(0, cursor - 1)
    }

    public mutating func moveRight() {
        cursor = min(text.count, cursor + 1)
    }

    /// Puts the cursor before the Character at `index`, clamped to `0...text.count`.
    public mutating func moveCursor(to index: Int) {
        cursor = min(max(0, index), text.count)
    }

    /// Empties the draft and returns what to send: each line as `.text` events of at most `maxEventBytes` UTF-8 bytes
    /// (never cut inside a character), and one `.returnKey` for every line break. No empty `.text`.
    public mutating func takeEvents() -> [EventKind] {
        var events: [EventKind] = []
        var segment = ""
        var segmentBytes = 0
        func flush() {
            if !segment.isEmpty { events.append(.text(segment)) }
            segment = ""
            segmentBytes = 0
        }
        for character in text {
            if character == "\n" {
                flush()
                events.append(.returnKey)
                continue
            }
            let bytes = String(character).utf8.count
            if segmentBytes + bytes > Self.maxEventBytes { flush() }
            segment.append(character)
            segmentBytes += bytes
        }
        flush()
        text = ""
        cursor = 0
        return events
    }
}

/// Maps a touch on the draft row to a cursor position. Pure: the view measures the character widths and the label
/// frames, this decides which boundary a touch is nearest and which boundaries a truncated label still shows.
///
/// A stop is a cursor position the user can see, with the x it is drawn at. Widths are per Character (a line break is
/// shown as one return mark, so it is one Character here too), which keeps the indices the draft's own.
public enum DraftCaretHitTest {
    public struct Stop: Equatable, Sendable {
        public let x: Double
        public let index: Int

        public init(x: Double, index: Int) {
            self.x = x
            self.index = index
        }
    }

    /// The visible cursor positions in the text before the caret. The label cuts its head, so it shows an ellipsis and
    /// then the longest tail of `widths` that fits `available`; positions in the hidden head are not offered, and a
    /// touch on the ellipsis lands on the first visible one. Positions run to `widths.count`, the caret itself.
    public static func stopsBefore(widths: [Double], originX: Double, available: Double, ellipsis: Double) -> [Stop] {
        var tail = widths.reduce(0, +)
        var first = 0
        while first < widths.count, tail + (first > 0 ? ellipsis : 0) > available {
            tail -= widths[first]
            first += 1
        }
        var x = originX + (first > 0 ? ellipsis : 0)
        var stops = [Stop(x: x, index: first)]
        for index in first..<widths.count {
            x += widths[index]
            stops.append(Stop(x: x, index: index + 1))
        }
        return stops
    }

    /// The visible cursor positions in the text after the caret, which starts at `baseIndex`. The label cuts its tail,
    /// so it shows the longest head of `widths` that fits `available` together with the ellipsis (none when everything
    /// fits). The caret position itself is always offered.
    public static func stopsAfter(
        widths: [Double], originX: Double, available: Double, ellipsis: Double, baseIndex: Int
    ) -> [Stop] {
        var xs = [originX]
        for width in widths { xs.append(xs[xs.count - 1] + width) }
        // The largest count that fits; all of them need no ellipsis, fewer need room for it.
        var shown = 0
        for count in widths.indices.map({ $0 + 1 }) where xs[count] - originX + (count < widths.count ? ellipsis : 0) <= available {
            shown = count
        }
        return (0...shown).map { Stop(x: xs[$0], index: baseIndex + $0) }
    }

    /// The index of the stop nearest `x`; the earlier one when two are equally near. `nil` without stops.
    public static func nearestIndex(x: Double, stops: [Stop]) -> Int? {
        var best: Stop?
        for stop in stops where best == nil || abs(stop.x - x) < abs(best!.x - x) { best = stop }
        return best?.index
    }
}
