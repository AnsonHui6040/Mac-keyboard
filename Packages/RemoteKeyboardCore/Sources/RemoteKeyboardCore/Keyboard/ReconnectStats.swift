import Foundation

/// One keyboard appearance. `connectedAtMs == nil` means the link was not connected within the 10 second window.
public struct ReconnectSample: Equatable, Sendable {
    public let shownAtMs: Int64
    public let connectedAtMs: Int64?

    public init(shownAtMs: Int64, connectedAtMs: Int64?) {
        self.shownAtMs = shownAtMs
        self.connectedAtMs = connectedAtMs
    }
}

public struct ReconnectSummary: Equatable, Sendable {
    public let attempts: Int
    public let successes: Int
    public let p95Ms: Int64?

    public init(attempts: Int, successes: Int, p95Ms: Int64?) {
        self.attempts = attempts
        self.successes = successes
        self.p95Ms = p95Ms
    }
}

public enum ReconnectStats {
    /// P95 counts successful samples only, nearest rank: the `ceil(0.95 * n)`-th smallest latency (1-based).
    public static func summarize(_ samples: [ReconnectSample]) -> ReconnectSummary {
        let latencies = samples.compactMap { sample in sample.connectedAtMs.map { $0 - sample.shownAtMs } }.sorted()
        guard !latencies.isEmpty else { return ReconnectSummary(attempts: samples.count, successes: 0, p95Ms: nil) }
        // Integer form of ceil(0.95 * n), so no floating point rounding can move the rank.
        let rank = (95 * latencies.count + 99) / 100
        return ReconnectSummary(attempts: samples.count, successes: latencies.count, p95Ms: latencies[rank - 1])
    }
}

/// The Receiver's reconnect log: one `shownAtMs,connectedAtMs,latencyMs` line per ping, no header.
/// Only numbers are ever written.
public enum ReconnectCSV {
    public static func line(shownAtMs: Int64, connectedAtMs: Int64) -> String {
        "\(shownAtMs),\(connectedAtMs),\(connectedAtMs - shownAtMs)"
    }

    /// Reads a log back into samples, skipping blank or malformed lines.
    public static func samples(from text: String) -> [ReconnectSample] {
        text.split(whereSeparator: \.isNewline).compactMap { row in
            let fields = row.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 3, let shown = Int64(fields[0]), let connected = Int64(fields[1]), Int64(fields[2]) != nil
            else { return nil }
            return ReconnectSample(shownAtMs: shown, connectedAtMs: connected)
        }
    }
}

/// Monotonic milliseconds from one fixed origin per process. Only differences between two readings are meaningful.
public enum MonotonicClock {
    private static let origin = ContinuousClock.now

    public static func nowMs() -> Int64 {
        let d = ContinuousClock.now - origin
        return d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000
    }
}

/// Timing of one keyboard appearance on the iPhone. `shownAtMs` is set when the owning controller's appearance starts,
/// `connectedAtMs` only on the first transition into `connected`, and the ping is handed out once.
public struct ReconnectTracker: Equatable, Sendable {
    public private(set) var shownAtMs: Int64?
    public private(set) var connectedAtMs: Int64?
    private var pinged = false

    public init() {}

    public var isActive: Bool { shownAtMs != nil }

    /// Connected minus shown, or `nil` until the link has connected in this appearance.
    public var latencyMs: Int64? {
        guard let shownAtMs, let connectedAtMs else { return nil }
        return connectedAtMs - shownAtMs
    }

    /// Starts an appearance unless one is already running (a repeated appear must not move `shownAtMs`).
    @discardableResult
    public mutating func beginIfIdle(atMs now: Int64) -> Bool {
        guard !isActive else { return false }
        shownAtMs = now
        return true
    }

    public mutating func reset() {
        shownAtMs = nil
        connectedAtMs = nil
        pinged = false
    }

    public mutating func linkChanged(from old: KeyboardLinkState, to new: KeyboardLinkState, atMs now: Int64) {
        guard isActive, connectedAtMs == nil, old != .connected, new == .connected else { return }
        connectedAtMs = now
    }

    /// The ping payload, once, and only when the link is connected and the first Receiver status has arrived.
    public mutating func takePing(statusReceived: Bool, linkConnected: Bool) -> (shownAtMs: Int64, connectedAtMs: Int64)? {
        guard !pinged, statusReceived, linkConnected, let shownAtMs, let connectedAtMs else { return nil }
        pinged = true
        return (shownAtMs, connectedAtMs)
    }
}
