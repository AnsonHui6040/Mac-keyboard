/// Remembers which service add is in flight, so a late `didAdd` from an earlier appearance cannot be mistaken for it.
///
/// A stale completion that reported success would start advertising before the current service is registered; one that
/// reported an error would leave the link stuck in a failed state.
public struct PendingServiceTracker<ID: Hashable & Sendable>: Sendable {
    public private(set) var pending: ID?

    public init() {}

    /// Starts tracking `id`, replacing whatever was pending.
    public mutating func begin(_ id: ID) { pending = id }

    /// True, and the pending add is cleared, only when `id` is the one in flight. Anything else is ignored.
    public mutating func accept(_ id: ID) -> Bool {
        guard pending == id else { return false }
        pending = nil
        return true
    }

    /// Forgets the pending add, for teardown and `removeAllServices`.
    public mutating func clear() { pending = nil }
}
