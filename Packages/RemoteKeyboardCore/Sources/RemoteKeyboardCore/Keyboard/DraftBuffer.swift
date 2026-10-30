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
