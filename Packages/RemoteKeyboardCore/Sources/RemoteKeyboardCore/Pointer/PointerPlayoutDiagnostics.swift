import Foundation

/// Counters that tell where uneven cursor motion comes from, over the last 5 seconds. Pure logic; time is passed in and only
/// times, counts and ratios are kept: never a position or a displacement.
///
/// - **Stalled frames**: among the screen refreshes while the cursor is *moving* (a MOVE arrived in the last 100 ms), the share
///   where the playout handed out nothing, and the longest run of them in a row. This points at the queue running empty.
/// - **Squeezes**: how often a new packet made the playout squeeze its queue to hold the lag bound.
/// - **Refresh callbacks**: the gap between callbacks, and the margin between the callback and the `targetTimestamp` of its
///   frame. A small margin means the callback runs close to the compositor's deadline.
/// - **Starvation**: while the cursor is moving, a MOVE arrived after the playout had already played out everything queued. The
///   time between the end of the queue and that arrival is a *standstill*; the count of such events and the P95 and the longest
///   standstill are kept. (A stalled frame cannot show this: the frame source is stopped while the queue is empty, so no frame
///   runs during the standstill.)
/// - **Gain jump**: `|ln(g_i / g_{i-1})|` for the speed curve's gain of two successive MOVE packets of one stroke (less than
///   100 ms apart). The Mac applies one gain per packet, so a jump shows up as a step in cursor speed at the packet's edge.
///
/// With fewer than 20 refreshes in the window there is nothing to show.
public struct PointerPlayoutDiagnostics: Sendable {
    public static let windowMicros: UInt64 = 5_000_000
    public static let minimumFrames = 20
    public static let movingMicros: UInt64 = 100_000
    public static let strokeGapMicros: UInt64 = 100_000

    public struct Snapshot: Equatable, Sendable {
        public var stalledFramePercent: Double
        public var longestStall: Int
        public var squeezeCount: Int
        public var callbackIntervalP50Millis: Double
        public var callbackIntervalP95Millis: Double
        public var marginP10Millis: Double
        public var marginP50Millis: Double
        public var gainJumpP50: Double
        public var gainJumpP90: Double
        public var starveCount: Int
        public var starveP95Millis: Double
        public var starveMaxMillis: Double
        /// Median over the starvation events of the phone's own `dt` on the packet that ended each, in ms.
        public var starveDtP50Millis: Double
        /// Median over the starvation events of the arrival gap to the previous MOVE, in ms.
        public var starveGapP50Millis: Double

        /// Short plain lines for the Receiver panel, one value each.
        public var lines: [String] {
            func whole(_ value: Double) -> Int { Int(value.rounded()) }
            return [
                "播放中斷 \(whole(stalledFramePercent))%（最長 \(longestStall) 幀）",
                "追趕壓縮 \(squeezeCount) 次",
                "刷新回呼間隔 P50 \(whole(callbackIntervalP50Millis)) ms，P95 \(whole(callbackIntervalP95Millis)) ms，餘裕 P10 \(whole(marginP10Millis)) ms",
                "加速倍率跳動 P50 \(String(format: "%.2f", gainJumpP50))，P90 \(String(format: "%.2f", gainJumpP90))",
                "佇列見底 \(starveCount) 次，P95 \(whole(starveP95Millis)) ms，最長 \(whole(starveMaxMillis)) ms",
            ]
        }
    }

    private struct Frame {
        var at: UInt64
        var moving: Bool
        var delivered: Bool
        /// Gap to the callback before, in ms; nil for the first.
        var interval: Double?
        var margin: Double
    }

    private var frames: [Frame] = []
    private var squeezes: [UInt64] = []
    private var jumps: [(at: UInt64, value: Double)] = []
    private var starvations: [(at: UInt64, millis: Double, dtMillis: Double, gapMillis: Double)] = []
    private var lastMoveAt: UInt64?
    private var lastGain: Double?
    private var lastTimestamp: UInt64?

    public init() {}

    /// A MOVE packet arrived (its displacement in 1/16 point and `dt` in tenths of a millisecond, as sent).
    public mutating func recordMove(arrivalMicros: UInt64, dxSixteenths: Int16, dySixteenths: Int16, dtTenths: UInt16) {
        let dx = Double(dxSixteenths) / 16, dy = Double(dySixteenths) / 16
        let speed = hypot(dx, dy) / PointerAcceleration.seconds(fromTenthsOfMs: dtTenths)
        let gain = PointerAcceleration.gain(speed: speed)
        if let previous = lastMoveAt, let before = lastGain, arrivalMicros &- previous < Self.strokeGapMicros {
            jumps.append((arrivalMicros, abs(log(gain / before))))
        }
        lastMoveAt = arrivalMicros
        lastGain = gain
    }

    /// The playout squeezed its queue on an arrival.
    public mutating func recordSqueeze(atMicros: UInt64) {
        squeezes.append(atMicros)
    }

    /// A MOVE arrived while moving and the playout had been empty for `standstillMicros`.
    /// `phoneDtMicros` is the ending packet's `dt` (the phone's time since its previous MOVE); `arrivalGapMicros` is the time
    /// since the previous MOVE arrived here. A large `dt` means the phone made the gap, a small one means the radio did.
    public mutating func recordStarvation(atMicros: UInt64, standstillMicros: UInt64, phoneDtMicros: UInt64 = 0, arrivalGapMicros: UInt64 = 0) {
        starvations.append((atMicros, Double(standstillMicros) / 1_000, Double(phoneDtMicros) / 1_000, Double(arrivalGapMicros) / 1_000))
    }

    /// The frame source was stopped: the next refresh is not measured against the one before the stop, so the idle gap does not
    /// count as a callback hitch.
    public mutating func frameSourceStopped() {
        lastTimestamp = nil
    }

    /// One screen refresh. `nowMicros` is when the callback ran, `timestampMicros` and `targetMicros` are the display link's own
    /// times of the frame (same clock); `delivered` is whether the playout handed out any movement.
    public mutating func recordFrame(nowMicros: UInt64, timestampMicros: UInt64, targetMicros: UInt64, delivered: Bool) {
        let moving = lastMoveAt.map { nowMicros &- $0 <= Self.movingMicros } ?? false
        let interval = lastTimestamp.map { Double(Int64(bitPattern: timestampMicros &- $0)) / 1_000 }
        lastTimestamp = timestampMicros
        let margin = Double(Int64(bitPattern: targetMicros &- nowMicros)) / 1_000
        frames.append(Frame(at: nowMicros, moving: moving, delivered: delivered, interval: interval, margin: margin))
        prune(nowMicros: nowMicros)
    }

    public mutating func reset() {
        self = PointerPlayoutDiagnostics()
    }

    public mutating func snapshot(nowMicros: UInt64) -> Snapshot? {
        prune(nowMicros: nowMicros)
        guard frames.count >= Self.minimumFrames else { return nil }
        let movingFrames = frames.filter(\.moving)
        let stalled = movingFrames.filter { !$0.delivered }.count
        var longest = 0, run = 0
        for frame in frames {
            if frame.moving, !frame.delivered {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        let intervals = frames.compactMap(\.interval).sorted()
        let margins = frames.map(\.margin).sorted()
        let jumpValues = jumps.map(\.value).sorted()
        let starveValues = starvations.map(\.millis).sorted()
        return Snapshot(
            stalledFramePercent: movingFrames.isEmpty ? 0 : Double(stalled) * 100 / Double(movingFrames.count),
            longestStall: longest, squeezeCount: squeezes.count,
            callbackIntervalP50Millis: Self.percentile(intervals, 0.5), callbackIntervalP95Millis: Self.percentile(intervals, 0.95),
            marginP10Millis: Self.percentile(margins, 0.1), marginP50Millis: Self.percentile(margins, 0.5),
            gainJumpP50: Self.percentile(jumpValues, 0.5), gainJumpP90: Self.percentile(jumpValues, 0.9),
            starveCount: starveValues.count, starveP95Millis: Self.percentile(starveValues, 0.95),
            starveMaxMillis: starveValues.last ?? 0,
            starveDtP50Millis: Self.percentile(starvations.map(\.dtMillis).sorted(), 0.5),
            starveGapP50Millis: Self.percentile(starvations.map(\.gapMillis).sorted(), 0.5))
    }

    private mutating func prune(nowMicros: UInt64) {
        let cutoff = nowMicros > Self.windowMicros ? nowMicros - Self.windowMicros : 0
        frames.removeAll { $0.at < cutoff }
        squeezes.removeAll { $0 < cutoff }
        jumps.removeAll { $0.at < cutoff }
        starvations.removeAll { $0.at < cutoff }
    }

    /// Nearest rank on a sorted list.
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
