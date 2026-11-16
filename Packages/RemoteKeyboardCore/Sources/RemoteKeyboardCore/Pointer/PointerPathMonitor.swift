import Foundation

/// Which way the cursor packets leave the iPhone right now.
public enum PointerPath: Equatable, Sendable {
    case bluetooth
    case wifi
}

/// Whether the Wi-Fi path is alive (spec W5, W7; docs/protocol/v4.md §8.6 rule 2).
///
/// The Receiver sends a probe every 250 ms; each one that opens (`handleProbe`) keeps the path alive for `liveWindowMicros`
/// (1000 ms, Provisional). Without a probe the path is Bluetooth, so the fallback needs no event: the next `path(atMicros:)`
/// after the window says so.
///
/// A real failure (`sendFailed`: the system refused a send, or the flow broke) drops the path at once and ignores probes for a
/// pause: when the local-network permission is denied, probes keep arriving (receiving needs no permission) while every send
/// fails, and without the pause the path would flip back to Wi-Fi after each failure. The pause backs off, 5 s (Provisional),
/// then 10, 20, ..., never more than `maxHoldoffMicros` (60 s); after `maxFailures` (3) failures in one channel Wi-Fi is given
/// up for that channel (`isWifiDisabled`). Failures reported inside a running pause are the same failure and count once.
/// `reset()` (the channel ended or a new one starts) forgets all of it.
///
/// Time is always passed in (`PointerClock.nowMicros()`). Single serial context only; nothing here is logged.
public struct PointerPathMonitor: Sendable {
    public let liveWindowMicros: UInt64
    public let failureHoldoffMicros: UInt64
    public let maxHoldoffMicros: UInt64
    public let maxFailures: Int
    private var lastProbeAt: UInt64?
    private var pausedUntil: UInt64?
    private var failures = 0

    public init(
        liveWindowMicros: UInt64 = 1_000_000, failureHoldoffMicros: UInt64 = 5_000_000,
        maxHoldoffMicros: UInt64 = 60_000_000, maxFailures: Int = 3
    ) {
        self.liveWindowMicros = liveWindowMicros
        self.failureHoldoffMicros = failureHoldoffMicros
        self.maxHoldoffMicros = maxHoldoffMicros
        self.maxFailures = maxFailures
    }

    /// Wi-Fi was given up for this channel: no probe counts any more.
    public var isWifiDisabled: Bool { failures >= maxFailures }

    /// A probe passed the checks of `ChannelOpener`. Ignored during the pause that follows a failed send.
    public mutating func probeAccepted(atMicros now: UInt64) {
        count(atMicros: now)
    }

    @discardableResult
    private mutating func count(atMicros now: UInt64) -> Bool {
        guard !isWifiDisabled else { return false }
        if let until = pausedUntil {
            guard now >= until else { return false }
            pausedUntil = nil
        }
        lastProbeAt = now
        return true
    }

    /// Opens `datagram` as a probe and counts it only when it opens: a forged, mangled, replayed or wrong-kind datagram
    /// leaves the path as it was. Returns whether the probe counted.
    @discardableResult
    public mutating func handleProbe(_ datagram: Data, opener: ChannelOpener, atMicros now: UInt64) -> Bool {
        guard case .success = opener.open(datagram) else { return false }
        return count(atMicros: now)
    }

    public func path(atMicros now: UInt64) -> PointerPath {
        guard let last = lastProbeAt else { return .bluetooth }
        let elapsed = now >= last ? now - last : 0
        return elapsed <= liveWindowMicros ? .wifi : .bluetooth
    }

    /// A real send failure: Bluetooth from now on, and no probe counts until the pause is over.
    public mutating func sendFailed(atMicros now: UInt64) {
        if let until = pausedUntil, now < until { return }
        lastProbeAt = nil
        failures += 1
        // 5 s, 10 s, 20 s, ... up to the cap; the shift is bounded so it cannot overflow.
        let doubled = failureHoldoffMicros << UInt64(min(failures - 1, 20))
        pausedUntil = now &+ min(doubled, maxHoldoffMicros)
    }

    /// A new channel, or the channel ended: back to Bluetooth with a clean slate.
    public mutating func reset() {
        lastProbeAt = nil
        pausedUntil = nil
        failures = 0
    }
}

/// Where one cursor packet leaves: over UDP, over the Bluetooth radio, or not yet because the radio is full.
public enum PointerRoute: Equatable, Sendable {
    case udp
    case bluetooth
    case wait

    /// UDP does not use the radio, so a full radio holds up Bluetooth packets only.
    public static func choose(path: PointerPath, radioBlocked: Bool) -> PointerRoute {
        switch path {
        case .wifi: .udp
        case .bluetooth: radioBlocked ? .wait : .bluetooth
        }
    }
}
