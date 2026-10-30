import Foundation

/// The time box of one pairing attempt. Time is injected, never read here.
///
/// The Mac opens it from its menu; the iPhone starts one when the pairing screen appears. Both sides use the same
/// length. Outside the window a Mac ignores a `pairOffer`, and an attempt that is still unconfirmed when the window
/// closes is discarded.
public struct PairingWindow: Sendable {
    public static let duration: TimeInterval = 120

    public private(set) var deadline: Date?

    public init() {}

    /// Opens, or restarts, the window for the full duration.
    public mutating func open(now: Date) {
        deadline = now.addingTimeInterval(Self.duration)
    }

    public mutating func close() { deadline = nil }

    /// False at the deadline itself. A clock that reads earlier than one full duration before the deadline cannot belong
    /// to this window (the clock jumped back), so it also reads as closed.
    public func isOpen(at now: Date) -> Bool {
        guard let deadline else { return false }
        return now < deadline && now >= deadline.addingTimeInterval(-Self.duration)
    }

    /// Seconds left, never negative; `nil` while closed.
    public func remaining(at now: Date) -> TimeInterval? {
        guard let deadline else { return nil }
        return max(0, deadline.timeIntervalSince(now))
    }
}
