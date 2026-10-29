import CoreGraphics
import Foundation
import OSLog
import RemoteKeyboardCore

/// Seam over posting so event construction can be tested without touching the real input stream.
@MainActor
protocol EventPosting {
    func post(_ events: [CGEvent])
}

struct HIDEventPoster: EventPosting {
    func post(_ events: [CGEvent]) {
        for event in events { event.post(tap: .cghidEventTap) }
    }
}

/// Types text into the focused Mac app as unicode keyboard events.
/// Never logs the text itself; only lengths and counts.
@MainActor
final class TextInjector {
    static let backspaceKey: CGKeyCode = 51
    static let returnKey: CGKeyCode = 36
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard.receiver", category: "inject")

    private let poster: EventPosting

    init(poster: EventPosting = HIDEventPoster()) {
        self.poster = poster
    }

    // MARK: Building (no side effects)

    /// A keyDown and keyUp pair carrying `text` as its unicode string. Empty when `text` is empty or creation fails.
    nonisolated static func makeTextEvents(_ text: String) -> [CGEvent] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }
        var events: [CGEvent] = []
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: keyDown) else { return [] }
            // Held modifiers would turn typed characters into shortcuts.
            event.flags = []
            event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            events.append(event)
        }
        return events
    }

    /// A keyDown and keyUp pair for a physical key such as Backspace or Return.
    nonisolated static func makeKeyEvents(virtualKey: CGKeyCode) -> [CGEvent] {
        var events: [CGEvent] = []
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: keyDown) else { return [] }
            event.flags = []
            events.append(event)
        }
        return events
    }

    // MARK: Posting

    /// Posts `text` split by `UnicodeChunker`. Returns the number of chunks posted.
    @discardableResult
    func insert(_ text: String) -> Int {
        var posted = 0
        for chunk in UnicodeChunker.chunks(text) where postChunk(chunk) { posted += 1 }
        Self.log.info("insert length \(text.utf16.count, privacy: .public) chunks \(posted, privacy: .public)")
        return posted
    }

    /// Posts `text` as a single event with no chunking, to measure the per-event limit. Returns whether it was posted.
    @discardableResult
    func insertUnchunked(_ text: String) -> Bool {
        let ok = postChunk(text)
        Self.log.info("insert unchunked length \(text.utf16.count, privacy: .public) posted \(ok, privacy: .public)")
        return ok
    }

    func backspace() { postKey(Self.backspaceKey) }
    func returnKeyPress() { postKey(Self.returnKey) }

    private func postChunk(_ chunk: String) -> Bool {
        let events = Self.makeTextEvents(chunk)
        guard !events.isEmpty else { return false }
        poster.post(events)
        return true
    }

    private func postKey(_ key: CGKeyCode) {
        let events = Self.makeKeyEvents(virtualKey: key)
        guard !events.isEmpty else { return }
        poster.post(events)
        Self.log.info("key \(key, privacy: .public)")
    }
}
