import Foundation

/// Counters that tell where uneven cursor motion comes from, over the last 5 seconds. Pure logic; time is passed in and only
/// times, counts and ratios are kept: never a position or a displacement.
///
/// - **Stalled frames**: among the screen refreshes while the cursor is *moving* (a MOVE arrived in the last 100 ms), the share
///   where the playout handed out nothing, and the longest run of them in a row. This points at the queue running empty.
/// - **Squeezes**: how often a new packet made the playout squeeze its queue to hold the lag bound.
/// - **Refresh callbacks**: the gap between callbacks, and the margin between the callback and the `targetTimestamp` of its
///   frame. A small margin means the callback runs close to the compositor's deadline.
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

        /// Short plain lines for the Receiver panel, one value each.
        public var lines: [String] {
            func whole(_ value: Double) -> Int { Int(value.rounded()) }
            return [
                "播放中斷 \(whole(stalledFramePercent))%（最長 \(longestStall) 幀）",
                "追趕壓縮 \(squeezeCount) 次",
                "刷新回呼間隔 P50 \(whole(callbackIntervalP50Millis)) ms，P95 \(whole(callbackIntervalP95Millis)) ms，餘裕 P10 \(whole(marginP10Millis)) ms",
                "加速倍率跳動 P50 \(String(format: "%.2f", gainJumpP50))，P90 \(String(format: "%.2f", gainJumpP90))",
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
        return Snapshot(
            stalledFramePercent: movingFrames.isEmpty ? 0 : Double(stalled) * 100 / Double(movingFrames.count),
            longestStall: longest, squeezeCount: squeezes.count,
            callbackIntervalP50Millis: Self.percentile(intervals, 0.5), callbackIntervalP95Millis: Self.percentile(intervals, 0.95),
            marginP10Millis: Self.percentile(margins, 0.1), marginP50Millis: Self.percentile(margins, 0.5),
            gainJumpP50: Self.percentile(jumpValues, 0.5), gainJumpP90: Self.percentile(jumpValues, 0.9))
    }

    private mutating func prune(nowMicros: UInt64) {
        let cutoff = nowMicros > Self.windowMicros ? nowMicros - Self.windowMicros : 0
        frames.removeAll { $0.at < cutoff }
        squeezes.removeAll { $0 < cutoff }
        jumps.removeAll { $0.at < cutoff }
    }

    /// Nearest rank on a sorted list.
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
