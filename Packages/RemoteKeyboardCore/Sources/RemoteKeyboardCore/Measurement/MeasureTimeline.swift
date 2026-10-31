#if DEBUG
import Foundation

/// The three fixed stretches of M5 (long text while round trips are measured).
public enum M5Phase: Int, CaseIterable, Hashable, Sendable {
    case baseline, load, recovery

    public var name: String { ["baseline", "load", "recovery"][rawValue] }
}

/// M5 runs on the clock, not on a sample count: baseline 20 s without text, load 60 s with a 3,000-character text every
/// second, recovery 30 s without text. A run in which any stretch has fewer than 30 round trips is invalid.
public enum M5Timeline {
    public static let baselineSeconds = 20
    public static let loadSeconds = 60
    public static let recoverySeconds = 30
    public static let minimumSamplesPerPhase = 30
    /// How many round trips in a row must be at or below the baseline's P95 before the run counts as recovered.
    public static let recoveryRunLength = 10

    private static func micros(_ seconds: Int) -> UInt64 { UInt64(seconds) * 1_000_000 }

    public static var totalMicros: UInt64 { micros(baselineSeconds + loadSeconds + recoverySeconds) }
    /// When the run stops sending text.
    public static var stopTextAtMicros: UInt64 { micros(baselineSeconds + loadSeconds) }

    /// The stretch at a time since the run started; `nil` once the run is over.
    public static func phase(atElapsedMicros elapsed: UInt64) -> M5Phase? {
        if elapsed < micros(baselineSeconds) { return .baseline }
        if elapsed < stopTextAtMicros { return .load }
        if elapsed < totalMicros { return .recovery }
        return nil
    }

    public static func isValid(counts: [M5Phase: Int]) -> Bool {
        M5Phase.allCases.allSatisfy { (counts[$0] ?? 0) >= minimumSamplesPerPhase }
    }

    /// Time from the end of the text until the `0x02` queue was empty (0 when it was already empty).
    public static func drainMicros(textStoppedAt: UInt64, queueEmptyAt: UInt64) -> UInt64 {
        queueEmptyAt > textStoppedAt ? queueEmptyAt - textStoppedAt : 0
    }

    /// Time from the empty queue until the first round trip of a run of `recoveryRunLength` that are all at or below the
    /// baseline's P95; `nil` when that never happens. A round trip is placed at the moment its probe was handed over.
    public static func recoverMicros(
        samples: [(sentMicros: UInt64, rttMs: Double)], drainedAtMicros: UInt64, baselineP95Ms: Double
    ) -> UInt64? {
        guard !baselineP95Ms.isNaN else { return nil }
        let after = samples.filter { $0.sentMicros >= drainedAtMicros }.sorted { $0.sentMicros < $1.sentMicros }
        var runStart: Int?
        for (index, sample) in after.enumerated() {
            guard sample.rttMs <= baselineP95Ms else {
                runStart = nil
                continue
            }
            if runStart == nil { runStart = index }
            if index - (runStart ?? index) + 1 >= recoveryRunLength, let start = runStart {
                return after[start].sentMicros - drainedAtMicros
            }
        }
        return nil
    }
}

/// One round of M7: a cursor baseline, then the switch to the touchpad with a long text still on its way, then a pause.
public enum ModeSwitchPlan {
    public static let baselineSeconds = 10
    public static let trackpadSeconds = 10
    public static let restSeconds = 3
    public static let defaultRuns = 20

    public enum Stage: Equatable, Sendable { case baseline, trackpad, rest }

    public static func stage(atIterationMicros elapsed: UInt64) -> Stage? {
        let seconds = Double(elapsed) / 1_000_000
        if seconds < Double(baselineSeconds) { return .baseline }
        if seconds < Double(baselineSeconds + trackpadSeconds) { return .trackpad }
        if seconds < Double(baselineSeconds + trackpadSeconds + restSeconds) { return .rest }
        return nil
    }
}

/// The traffic of M8, a stand-in for ten minutes of touchpad use: a cursor packet at 60 Hz (120 Hz for the last second of
/// every 5, the scroll stand-in), an `rtt` probe every 2 s (the click stand-in), and a heartbeat every 100 ms (the drag
/// stand-in). `due` says which kinds are to be sent at a time; it never returns a kind twice for one tick, so a tick that
/// was held up does not turn into a burst.
public struct M8Streams: Sendable {
    public static let cursorIntervalMicros: UInt64 = 16_667
    public static let scrollIntervalMicros: UInt64 = 8_333
    public static let rttIntervalMicros: UInt64 = 2_000_000
    public static let heartbeatIntervalMicros: UInt64 = 100_000
    private static let cycleMicros: UInt64 = 5_000_000
    private static let burstStartMicros: UInt64 = 4_000_000

    private var cursor = Pacer()
    private var rtt = Pacer()
    private var heartbeat = Pacer()

    public init() {}

    /// The last second of every 5 seconds.
    public static func isScrollBurst(atElapsedMicros elapsed: UInt64) -> Bool {
        elapsed % cycleMicros >= burstStartMicros
    }

    public mutating func due(atElapsedMicros now: UInt64) -> [MeasurePayload.Kind] {
        var kinds: [MeasurePayload.Kind] = []
        if rtt.due(atMicros: now, interval: Self.rttIntervalMicros) { kinds.append(.rtt) }
        if heartbeat.due(atMicros: now, interval: Self.heartbeatIntervalMicros) { kinds.append(.heartbeat) }
        let cursorInterval = Self.isScrollBurst(atElapsedMicros: now) ? Self.scrollIntervalMicros : Self.cursorIntervalMicros
        if cursor.due(atMicros: now, interval: cursorInterval) { kinds.append(.cursor) }
        return kinds
    }
}

/// A steady beat that is asked about on every tick: is a packet due now? The deadline moves in fixed steps from the previous
/// deadline, so the beat does not drift; when a tick was held up for more than a whole interval the beat restarts from now
/// instead of sending the missed packets in a burst. The first question is always yes.
public struct Pacer: Sendable {
    private var next: UInt64?

    public init() {}

    public mutating func due(atMicros now: UInt64, interval: UInt64) -> Bool {
        guard let deadline = next else {
            next = now + interval
            return true
        }
        guard now >= deadline else { return false }
        next = now > deadline + interval ? now + interval : deadline + interval
        return true
    }
}

/// How many `0x02` frames the exit handed over in each second of a window (M7: while the touchpad sends, the long text must
/// still move). Only the seconds in which the text was still waiting count: up to the second in which the queue ran empty.
public enum FrameRate {
    public struct Summary: Equatable, Sendable {
        public let perSecond: [Int]
        /// `nil` when the text was not waiting in any second of the window.
        public let minPerSecond: Int?
        /// Seconds in which the text was waiting and not one frame went out.
        public let starvedSeconds: Int
    }

    /// - Parameters:
    ///   - queueEmptyAtMicros: when the last frame left and the queue was empty; `nil` when it was not empty by the end of the window.
    public static func summarize(
        frameMicros: [UInt64], windowStartMicros: UInt64, windowSeconds: Int, queueEmptyAtMicros: UInt64?
    ) -> Summary {
        let end = windowStartMicros + UInt64(windowSeconds) * 1_000_000
        let inWindow = frameMicros.filter { $0 >= windowStartMicros && $0 < end }
        var active = windowSeconds
        if let empty = queueEmptyAtMicros {
            if inWindow.isEmpty || empty < windowStartMicros {
                return Summary(perSecond: [], minPerSecond: nil, starvedSeconds: 0)
            }
            active = min(windowSeconds, Int((empty - windowStartMicros) / 1_000_000) + 1)
        }
        var counts = [Int](repeating: 0, count: active)
        for time in inWindow {
            let bucket = Int((time - windowStartMicros) / 1_000_000)
            if bucket < active { counts[bucket] += 1 }
        }
        return Summary(perSecond: counts, minPerSecond: counts.min(), starvedSeconds: counts.filter { $0 == 0 }.count)
    }
}
#endif
