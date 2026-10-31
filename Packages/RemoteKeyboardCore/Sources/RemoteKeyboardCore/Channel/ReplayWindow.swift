import Foundation

/// Sliding replay window over a strictly positive 64-bit counter: the largest counter seen so far and a bitmap of the 64
/// counters below it. `check` and `commit` are separate on purpose: the caller commits only after the packet's tag
/// verified, so a forged packet with a huge counter cannot move the window.
public struct ReplayWindow: Equatable, Sendable {
    public enum Verdict: Equatable, Sendable {
        case accept
        /// Counter 0, the maximum itself, or a counter inside the window that was already committed.
        case replayed
        /// More than 64 below the maximum.
        case tooOld
    }

    private static let span: UInt64 = 64

    private var maximum: UInt64 = 0
    /// Bit `i` set means counter `maximum − 1 − i` was committed.
    private var seen: UInt64 = 0

    public init() {}

    public func verdict(_ counter: UInt64) -> Verdict {
        guard counter != 0 else { return .replayed }
        guard counter <= maximum else { return .accept }
        let distance = maximum - counter
        guard distance != 0 else { return .replayed }
        guard distance <= Self.span else { return .tooOld }
        return seen & (1 << (distance - 1)) == 0 ? .accept : .replayed
    }

    public func check(_ counter: UInt64) -> Bool { verdict(counter) == .accept }

    /// Records a counter whose packet verified. A counter the window refuses is ignored.
    public mutating func commit(_ counter: UInt64) {
        guard verdict(counter) == .accept else { return }
        if counter > maximum {
            let shift = counter - maximum
            seen = shift >= 64 ? 0 : seen << shift
            // The old maximum is now `shift` below the new one.
            if shift <= Self.span { seen |= 1 << (shift - 1) }
            maximum = counter
        } else {
            seen |= 1 << (maximum - counter - 1)
        }
    }
}
