import Foundation

/// The T13 dictation probe's memory-only state: the last snapshot of the text around the cursor, the counters the
/// checklist shows, and the rules that decide whether a change becomes events. Pure; it never holds more than the one
/// snapshot, never writes anything out, and the controller only logs lengths and counts.
///
/// A snapshot is `documentContextBeforeInput` and `documentContextAfterInput`. The "after" half exists to tell a
/// cursor move (same text, different split) from an edit.
public struct DictationMirror: Equatable, Sendable {
    public static let maxBackspaces = 50
    public static let maxCharacters = 500
    /// Seconds after our own `insertText` / `deleteBackward` during which a text change is ours, not dictation's.
    public static let ownEditWindow: TimeInterval = 0.5

    public enum Outcome: Equatable, Sendable {
        case baselineSet
        case unchanged
        /// The text did not change, only where the cursor sits.
        case cursorMoved
        /// The change came from our own keys (Local mode); the baseline moved without sending anything.
        case ownEdit
        /// The difference exceeded the caps; the baseline moved without sending anything.
        case tooLarge
        case events([EventKind])
    }

    private struct Snapshot: Equatable, Sendable {
        let before: String
        let after: String
    }

    private var baseline: Snapshot?
    private var ownEditAt: TimeInterval?

    /// Only numbers, so the controller can keep them across a keyboard that was torn down and rebuilt during dictation.
    public struct Counters: Codable, Equatable, Sendable {
        /// `textWillChange` / `textDidChange` calls seen while the probe is on.
        public var willChangeCalls = 0
        public var didChangeCalls = 0
        /// Times the text before the cursor grew without our own keys typing.
        public var externalGrowths = 0
        /// Lengths of the last accepted difference.
        public var lastBackspaces = 0
        public var lastCharacters = 0
        /// Differences that were too large and reset the baseline.
        public var resets = 0
        public var eventsSent = 0
        public var eventsAcked = 0
        /// Events that went into the draft instead of the Mac.
        public var eventsDrafted = 0
        /// How often the keyboard view appeared and disappeared while the probe was on.
        public var appearances = 0
        public var disappearances = 0

        public init() {}
    }

    public private(set) var counters: Counters

    public init(counters: Counters = Counters()) { self.counters = counters }

    public var hasBaseline: Bool { baseline != nil }

    public mutating func noteWillChange() { counters.willChangeCalls += 1 }
    public mutating func noteSent(_ count: Int) { counters.eventsSent += count }
    public mutating func noteDrafted(_ count: Int) { counters.eventsDrafted += count }
    public mutating func noteAppeared() { counters.appearances += 1 }
    public mutating func noteDisappeared() { counters.disappearances += 1 }
    public mutating func noteAcked() { counters.eventsAcked += 1 }

    /// Our own keys are about to change the field; changes that arrive soon after are not dictation.
    public mutating func noteOwnEdit(at time: TimeInterval) { ownEditAt = time }

    /// Forgets the old snapshot and takes this one (the probe was switched on, the mode changed).
    public mutating func rebaseline(before: String, after: String) {
        baseline = Snapshot(before: before, after: after)
        ownEditAt = nil
    }

    public mutating func observe(before: String, after: String, at time: TimeInterval) -> Outcome {
        counters.didChangeCalls += 1
        let current = Snapshot(before: before, after: after)
        guard let previous = baseline else {
            baseline = current
            return .baselineSet
        }
        if let editedAt = ownEditAt, time - editedAt <= Self.ownEditWindow {
            baseline = current
            return .ownEdit
        }
        if current == previous { return .unchanged }
        baseline = current
        if previous.before + previous.after == before + after { return .cursorMoved }
        let counts = ContextDiff.counts(before: previous.before, after: before)
        if counts.backspaces > Self.maxBackspaces || counts.characters > Self.maxCharacters {
            counters.resets += 1
            return .tooLarge
        }
        let events = ContextDiff.events(before: previous.before, after: before)
        if events.isEmpty { return .unchanged }
        if before.count > previous.before.count { counters.externalGrowths += 1 }
        counters.lastBackspaces = counts.backspaces
        counters.lastCharacters = counts.characters
        return .events(events)
    }
}
