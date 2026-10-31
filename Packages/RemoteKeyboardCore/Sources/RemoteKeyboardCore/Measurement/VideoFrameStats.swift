import Foundation

/// M4 statistics from frame numbers read off a high-speed video (spec §13.3). A row holds the frame of the first finger
/// movement (T0), the iPhone test surface turning white (T2, if it was read), the Mac corner window turning white (T5′,
/// if it was read) and the Mac cursor starting to move (T6).
public struct VideoFrameStats: Sendable {
    public let fps: Double
    /// T6 − T0, the gate metric.
    public let e2e: LatencyStats
    /// T6 − T2 over the rows that have a T2; `nil` when none has.
    public let transportToDisplay: LatencyStats?
    /// T6 − T5′ over the rows that have a T5′; `nil` when none has.
    public let macDisplay: LatencyStats?

    public init(fps: Double, rows: [(t0: Int, t2: Int?, t5p: Int?, t6: Int)]) {
        self.fps = fps
        let frameMs = 1000 / fps
        e2e = LatencyStats(samplesMs: rows.map { Double($0.t6 - $0.t0) * frameMs })
        let toDisplay = rows.compactMap { row in row.t2.map { Double(row.t6 - $0) * frameMs } }
        let toMac = rows.compactMap { row in row.t5p.map { Double(row.t6 - $0) * frameMs } }
        transportToDisplay = toDisplay.isEmpty ? nil : LatencyStats(samplesMs: toDisplay)
        macDisplay = toMac.isEmpty ? nil : LatencyStats(samplesMs: toMac)
    }

    /// One frame, which is how finely every reading is quantized.
    public var quantizationErrorMs: Double { 1000 / fps }

    /// Whether the E2E P95 is within two frames of the target (the "decide with more samples" band).
    public func isBorderline(target: Double) -> Bool {
        guard e2e.count > 0 else { return false }
        return abs(e2e.p95 - target) <= 2 * quantizationErrorMs
    }
}
