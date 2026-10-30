import Foundation

/// When the dictation sync (D18) runs. Pure, so the rule is tested without UIKit.
public enum DictationSync {
    /// The App Group value of 「聽寫同步到 Mac」. Not set, or not a `Bool`, means on.
    public static func isEnabled(stored: Any?) -> Bool {
        (stored as? Bool) ?? true
    }

    /// The sync runs in Remote mode with the setting on, in Debug and Release alike. Local mode never syncs.
    public static func isActive(mode: KeyboardMode, storedSetting: Any?) -> Bool {
        mode == .remote && isEnabled(stored: storedSetting)
    }

    /// Whether a difference goes into the draft rather than straight to the Mac. The same rule `InputRouter` applies
    /// to a typing key in Remote mode.
    public static func goesToDraft(transmit: TransmitMode, draftEmpty: Bool, ready: Bool) -> Bool {
        transmit == .draft || !draftEmpty || !ready
    }

    /// A difference that deletes text may only be applied to the draft when the draft cursor sits right behind that
    /// same text. `deleted` is `DictationMirror.lastDeleted`; it stays in memory and is never logged.
    public static func draftAccepts(deleted: String, draft: DraftBuffer) -> Bool {
        deleted.isEmpty || draft.textBeforeCursor.hasSuffix(deleted)
    }
}

/// The dictation sync's memory-only state (T13 probe, productized in T13b): the last snapshot of the text around the
/// cursor, the counters the Debug checklist shows, and the rules that decide whether a change becomes events. Pure; it
/// never holds more than the one snapshot, never writes anything out, and the controller only logs lengths and counts.
///
/// A snapshot is `documentContextBeforeInput`, `documentContextAfterInput` and the document identifier. The "after"
/// half exists to tell a cursor move (same text, different split) from an edit; the identifier tells another field
/// from the same one. iOS only hands out the text near the cursor, so a window that slid or jumped is not an edit.
public struct DictationMirror: Equatable, Sendable {
    public static let maxBackspaces = 50
    public static let maxCharacters = 500
    /// Seconds after our own `insertText` / `deleteBackward` during which a text change is ours, not dictation's.
    public static let ownEditWindow: TimeInterval = 0.5
    /// The Debug checklist switch is only restored for this long after it was turned on, so a forgotten panel in a
    /// Debug build does not stay up for good. It controls the panel and its counts only, not the sync.
    public static let leaseSeconds: TimeInterval = 30 * 60
    /// A window whose old text shares nothing with the new text is not trusted once the old text is at least this
    /// many Characters long: it slid or jumped, and a diff would delete text that was never edited.
    public static let untrustedMinimumLength = 10

    public enum Outcome: Equatable, Sendable {
        case baselineSet
        case unchanged
        /// The text did not change, only where the cursor sits.
        case cursorMoved
        /// The change came from our own keys (Local mode); the baseline moved without sending anything.
        case ownEdit
        /// The difference exceeded the caps; the baseline moved without sending anything.
        case tooLarge
        /// Another field or document: the baseline moved without sending anything.
        case documentChanged
        /// Nothing at the start of the old window survives in the new one, so the window slid or jumped; the baseline
        /// moved without sending anything.
        case untrusted
        case events([EventKind])
    }

    private struct Snapshot: Equatable, Sendable {
        let before: String
        let after: String
        let documentId: UUID?
    }

    private var baseline: Snapshot?
    private var ownEditAt: TimeInterval?
    /// The Characters the last `.events` difference deletes (the tail of the old snapshot after the shared start).
    /// Memory only; the controller compares it with the draft and never logs it.
    public private(set) var lastDeleted = ""

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
        /// Windows that slid or jumped and were not sent.
        public var untrusted = 0
        /// Times a change only set the baseline (nothing was sent). A sentence spoken while this rises may be missing
        /// on the Mac.
        public var baselines = 0
        /// Times the field turned out to be another document.
        public var documentChanges = 0
        /// Differences with backspaces dropped whole because the draft did not end with the text they delete.
        public var draftSkipped = 0
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
    /// A `textDidChange` that was not compared (there is no baseline and the field's text is not loaded yet).
    public mutating func noteDidChange() { counters.didChangeCalls += 1 }
    public mutating func noteSent(_ count: Int) { counters.eventsSent += count }
    public mutating func noteDrafted(_ count: Int) { counters.eventsDrafted += count }
    public mutating func noteAppeared() { counters.appearances += 1 }
    public mutating func noteDisappeared() { counters.disappearances += 1 }
    public mutating func noteAcked() { counters.eventsAcked += 1 }

    /// Our own keys are about to change the field; changes that arrive soon after are not dictation.
    public mutating func noteOwnEdit(at time: TimeInterval) { ownEditAt = time }

    /// The controller dropped a difference whose backspaces did not meet the draft's text (the draft cursor moved away
    /// or the draft was edited since iOS wrote what it is now revising).
    public mutating func noteDraftSkipped() { counters.draftSkipped += 1 }

    /// Which callback is asking for a first baseline.
    public enum BaselinePhase: Sendable {
        /// `textWillChange`: the field is about to be edited, so it is loaded.
        case willChange
        /// `textDidChange` and `viewDidAppear`: the field may simply not be loaded yet.
        case didChangeOrAppear
    }

    /// What a keyboard that has no baseline yet may take as one. A loaded `before` is the text. `nil` is how iOS answers
    /// for an empty field and for one that is not loaded yet; only `textWillChange` may read it as an empty field, and
    /// only when the field itself says it has no text (`hasText` is `false`). Everywhere else, and when `hasText` is
    /// `true`, it is `nil`: no baseline is taken and nothing is sent until a change carries text.
    public static func initialBaselineText(before: String?, hasText: Bool, phase: BaselinePhase) -> String? {
        if let before { return before }
        return phase == .willChange && !hasText ? "" : nil
    }

    /// Forgets the old snapshot and takes this one (the probe was switched on, the mode changed). A `nil` text before
    /// the cursor is how iOS answers while a field is not loaded yet, so it sets nothing: the first real change then
    /// only sets the baseline. Returns whether a baseline was set.
    @discardableResult
    public mutating func rebaseline(before: String?, after: String?, documentId: UUID? = nil) -> Bool {
        ownEditAt = nil
        guard let before else { return false }
        baseline = Snapshot(before: before, after: after ?? "", documentId: documentId)
        return true
    }

    /// Whether a switch turned on at `startedAt` (wall-clock seconds) may still be restored at `now`.
    public static func isLeaseValid(startedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let startedAt, now >= startedAt else { return false }
        return now - startedAt <= leaseSeconds
    }

    /// A `textDidChange` call.
    public mutating func observe(
        before: String, after: String, documentId: UUID? = nil, at time: TimeInterval
    ) -> Outcome {
        counters.didChangeCalls += 1
        return evaluate(before: before, after: after, documentId: documentId, at: time)
    }

    /// The keyboard appeared again with a baseline: compares once, without counting a `textDidChange`. With no baseline
    /// it returns `nil` and takes none; with a `nil` text before the cursor (the field may not be loaded yet) it also
    /// returns `nil` and leaves the baseline alone.
    public mutating func observeOnAppear(
        before: String?, after: String?, documentId: UUID?, at time: TimeInterval
    ) -> Outcome? {
        guard baseline != nil, let before else { return nil }
        return evaluate(before: before, after: after ?? "", documentId: documentId, at: time)
    }

    private mutating func evaluate(
        before: String, after: String, documentId: UUID?, at time: TimeInterval
    ) -> Outcome {
        lastDeleted = ""
        let current = Snapshot(before: before, after: after, documentId: documentId)
        guard let previous = baseline else {
            baseline = current
            counters.baselines += 1
            return .baselineSet
        }
        if previous.documentId != documentId {
            baseline = current
            counters.documentChanges += 1
            return .documentChanged
        }
        if let editedAt = ownEditAt, time - editedAt <= Self.ownEditWindow {
            baseline = current
            return .ownEdit
        }
        if current == previous { return .unchanged }
        baseline = current
        if previous.before + previous.after == before + after { return .cursorMoved }
        let counts = ContextDiff.counts(before: previous.before, after: before)
        // Every old Character would be deleted: the shared start is empty.
        if counts.backspaces == previous.before.count, previous.before.count >= Self.untrustedMinimumLength {
            counters.untrusted += 1
            return .untrusted
        }
        if counts.backspaces > Self.maxBackspaces || counts.characters > Self.maxCharacters {
            counters.resets += 1
            return .tooLarge
        }
        let events = ContextDiff.events(before: previous.before, after: before)
        if events.isEmpty { return .unchanged }
        if before.count > previous.before.count { counters.externalGrowths += 1 }
        counters.lastBackspaces = counts.backspaces
        counters.lastCharacters = counts.characters
        lastDeleted = String(previous.before.suffix(counts.backspaces))
        return .events(events)
    }
}
