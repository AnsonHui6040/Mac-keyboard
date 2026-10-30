/// What changed between two snapshots of the text before the cursor, as the keys that would turn the first into
/// the second: one `.backspace` per deleted `Character`, then one `.text` for what was inserted. Pure.
///
/// T13 uses it to mirror what iOS dictation wrote into the host field. Apple's corrections replace a word after a
/// pause, which shows up as a deleted tail plus a new tail.
public enum ContextDiff {
    public struct Counts: Equatable, Sendable {
        public let backspaces: Int
        public let characters: Int
    }

    public static func events(before: String, after: String) -> [EventKind] {
        let (deleted, inserted) = split(before: before, after: after)
        var events = [EventKind](repeating: .backspace, count: deleted)
        if !inserted.isEmpty { events.append(.text(inserted)) }
        return events
    }

    /// Lengths only (backspaces, inserted characters), for logs and for the size cap.
    public static func counts(before: String, after: String) -> Counts {
        let (deleted, inserted) = split(before: before, after: after)
        return Counts(backspaces: deleted, characters: inserted.count)
    }

    private static func split(before: String, after: String) -> (deleted: Int, inserted: String) {
        var left = before.startIndex
        var right = after.startIndex
        while left < before.endIndex, right < after.endIndex, before[left] == after[right] {
            left = before.index(after: left)
            right = after.index(after: right)
        }
        return (before[left...].count, String(after[right...]))
    }
}
