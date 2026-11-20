#if DEBUG
import Foundation

/// The result line of the Quick engine measurement (latency, memory, staging, App Group read). Numbers only: no typed
/// text, code or candidate is ever part of it. `limit_mb` is the footprint peak plus the smallest available memory.
public struct RimeMeasureLine: Equatable, Sendable {
    public var engine: QuickEngine
    public var keys: Int
    public var p50Us: Int
    public var p95Us: Int
    public var footprintPeakMB: Double
    public var availableMinMB: Double
    public var stagingBins: Int
    public var appGroupRead: Bool

    public init(
        engine: QuickEngine, keys: Int, p50Us: Int, p95Us: Int, footprintPeakMB: Double, availableMinMB: Double,
        stagingBins: Int, appGroupRead: Bool
    ) {
        self.engine = engine
        self.keys = keys
        self.p50Us = p50Us
        self.p95Us = p95Us
        self.footprintPeakMB = footprintPeakMB
        self.availableMinMB = availableMinMB
        self.stagingBins = stagingBins
        self.appGroupRead = appGroupRead
    }

    public var text: String {
        func one(_ value: Double) -> String { String(format: "%.1f", value) }
        return "RKMEAS RIME engine=\(engine.rawValue) keys=\(keys) p50_us=\(p50Us) p95_us=\(p95Us) "
            + "footprint_peak_mb=\(one(footprintPeakMB)) available_min_mb=\(one(availableMinMB)) "
            + "limit_mb=\(one(footprintPeakMB + availableMinMB)) staging_bins=\(stagingBins) appgroup_read=\(appGroupRead ? 1 : 0)"
    }
}
#endif
