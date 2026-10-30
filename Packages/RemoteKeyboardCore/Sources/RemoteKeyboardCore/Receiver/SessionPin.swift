import Foundation

/// Ties one authenticated connection to a single keyboard session.
///
/// The first `sessionId` an authenticated connection carries is pinned; any other id on the same connection is refused,
/// and the Receiver treats that as an authentication failure. A recorded sealed event can then not be replayed into a
/// live connection under a session the keyboard never opened on it. Single-use: one pin per connection.
public struct SessionPin: Sendable {
    private var pinned: UUID?

    public init() {}

    /// `true` when `sessionId` is the pinned one (or becomes it).
    public mutating func accept(_ sessionId: UUID) -> Bool {
        guard let pinned else {
            pinned = sessionId
            return true
        }
        return pinned == sessionId
    }
}
