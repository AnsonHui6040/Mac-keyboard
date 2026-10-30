import Foundation

/// Builds the events of one keyboard appearance and counts the ones the Receiver has not answered yet.
///
/// A key is pending from `make` until its ack arrives. When the link drops, `linkLost()` reports how many keys are
/// still unconfirmed and forgets them: they are never sent again, because the Receiver may or may not have typed them.
public struct EventSender: Sendable {
    public let sessionId: UUID
    private var seq: UInt64 = 0
    private var pending: Set<UUID> = []

    public init(sessionId: UUID) {
        self.sessionId = sessionId
    }

    /// Typed keys sent and not yet acknowledged. Probes are not counted.
    public var pendingCount: Int { pending.count }

    /// Numbers the event from 1 within the session. A probe carries no focus epoch whatever is passed.
    public mutating func make(_ kind: EventKind, focusEpoch: UInt64?) -> KeyboardEvent {
        seq += 1
        let event = KeyboardEvent(
            protocolVersion: KeyboardEvent.currentVersion, eventId: UUID(), sessionId: sessionId, seq: seq,
            focusEpoch: kind.carriesFocusEpoch ? focusEpoch : nil, kind: kind)
        if kind.carriesFocusEpoch { pending.insert(event.eventId) }
        return event
    }

    /// Any answer, including a refusal, settles the key: the Receiver handled it.
    public mutating func acknowledged(_ ack: Ack) {
        pending.remove(ack.eventId)
    }

    /// An event made but never handed to the radio (encoding failed). It is not pending, and when it is the newest
    /// its number is reused so the Receiver sees no gap.
    public mutating func unsent(_ event: KeyboardEvent) {
        pending.remove(event.eventId)
        if event.seq == seq { seq -= 1 }
    }

    /// The link went away. Returns how many keys never got an answer and clears them; nothing is resent.
    public mutating func linkLost() -> Int {
        let count = pending.count
        pending.removeAll()
        return count
    }
}
