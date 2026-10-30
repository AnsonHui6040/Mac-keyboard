import Foundation

/// The deadline of one liveness probe. The keyboard sends a probe event when it appears on a link that looks connected;
/// the Receiver answers `pong` for it. No answer within `timeoutMs` means the link is dead. Time is injected, never read.
public struct LinkProbe: Equatable, Sendable {
    public static let timeoutMs: Int64 = 2000

    private var pending: (eventId: UUID, deadlineMs: Int64)?

    public init() {}

    public var isPending: Bool { pending != nil }

    public static func == (lhs: LinkProbe, rhs: LinkProbe) -> Bool {
        lhs.pending?.eventId == rhs.pending?.eventId && lhs.pending?.deadlineMs == rhs.pending?.deadlineMs
    }

    /// Starts the clock for the probe event `eventId`. A probe already pending keeps its own deadline and `false` is
    /// returned: the caller does not send a second one.
    @discardableResult
    public mutating func start(eventId: UUID, nowMs: Int64) -> Bool {
        guard pending == nil else { return false }
        pending = (eventId, nowMs + Self.timeoutMs)
        return true
    }

    /// `true` when `eventId` is the pending probe; its deadline is then gone. Any other id changes nothing.
    @discardableResult
    public mutating func pongReceived(eventId: UUID) -> Bool {
        guard let pending, pending.eventId == eventId else { return false }
        self.pending = nil
        return true
    }

    /// Whether a pending probe has run out of time. Always `false` when none is pending.
    public func isExpired(nowMs: Int64) -> Bool {
        guard let pending else { return false }
        return nowMs >= pending.deadlineMs
    }

    public mutating func cancel() { pending = nil }
}
