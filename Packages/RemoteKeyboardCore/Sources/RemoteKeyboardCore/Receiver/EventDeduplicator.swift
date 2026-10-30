import Foundation

/// What the Receiver should do with an event it has just decoded.
public enum DedupDecision: Equatable, Sendable {
    /// Not seen before and newer than everything seen in its session: process it.
    case fresh
    /// The same `eventId` was already processed: answer with the original result and do nothing else.
    case duplicate(AckCode)
    /// A new `eventId` whose `seq` is not above the highest one seen in its session: do not process it.
    case outOfOrder
}

/// Remembers the most recent processed events so a repeated delivery is acknowledged but never typed twice, and an
/// event that arrives behind a newer one of the same session is refused.
///
/// `check` never changes state; `record` is called once the event has been processed. Pings are not passed through
/// here. Only the last `capacity` event ids are kept, so a duplicate older than that reads as out of order (its
/// `seq` is below the maximum) rather than as fresh.
public struct EventDeduplicator: Sendable {
    public let capacity: Int
    private var results: [UUID: AckCode] = [:]
    /// Oldest first; mirrors the keys of `results`.
    private var order: [UUID] = []
    private var sessionId: UUID?
    private var highestSeq: UInt64 = 0

    public init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    public func check(_ e: KeyboardEvent) -> DedupDecision {
        if let original = results[e.eventId] { return .duplicate(original) }
        if e.sessionId == sessionId, e.seq <= highestSeq { return .outOfOrder }
        return .fresh
    }

    public mutating func record(_ e: KeyboardEvent, result: AckCode) {
        if e.sessionId != sessionId {
            sessionId = e.sessionId
            highestSeq = 0
        }
        highestSeq = max(highestSeq, e.seq)
        if results.updateValue(result, forKey: e.eventId) == nil { order.append(e.eventId) }
        while order.count > capacity { results[order.removeFirst()] = nil }
    }
}
