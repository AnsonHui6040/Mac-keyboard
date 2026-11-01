import Foundation

/// What the Mac can tell about the touchpad link from the packets it receives, over the last 5 seconds. Pure logic; time is
/// passed in (the arrival time is the Mac's own clock, so it includes system scheduling). Only times and counts are kept.
///
/// Measured: packets per second, and the gaps between arrivals (P50, P95). **Estimated**: the connection interval (arrivals
/// less than 3 ms apart are taken as one batch; the median gap between batch starts) and the backlog (how much further the
/// arrival time has run from the phone's own timeline, the running sum of the packets' `dt`, since the last new stroke, a gap of
/// more than 100 ms). With fewer than 20 samples there is nothing to show.
public struct PointerLinkStats: Sendable {
    public static let windowMicros: UInt64 = 5_000_000
    public static let minimumSamples = 20
    public static let batchGapMicros: UInt64 = 3_000
    public static let strokeGapMicros: UInt64 = 100_000

    public struct Snapshot: Equatable, Sendable {
        public var packetsPerSecond: Double
        public var arrivalP50Millis: Double
        public var arrivalP95Millis: Double
        /// Estimated.
        public var estimatedConnectionIntervalMillis: Double
        /// Estimated; may be negative when the Mac catches up.
        public var backlogGrowthMillis: Double

        /// Short plain lines for the Receiver panel, one value each.
        public var lines: [String] {
            func whole(_ value: Double) -> Int { Int(value.rounded()) }
            return [
                "每秒封包 \(whole(packetsPerSecond))",
                "到達間隔 P50 \(whole(arrivalP50Millis)) ms，P95 \(whole(arrivalP95Millis)) ms",
                "推估連線間隔 \(whole(estimatedConnectionIntervalMillis)) ms",
                "推估積壓 \(max(0, whole(backlogGrowthMillis))) ms",
            ]
        }
    }

    private struct Sample {
        var arrival: UInt64
        var dtTenths: UInt16
    }

    private var samples: [Sample] = []

    public init() {}

    public mutating func record(arrivalMicros: UInt64, dtTenths: UInt16) {
        samples.append(Sample(arrival: arrivalMicros, dtTenths: dtTenths))
        prune(nowMicros: arrivalMicros)
    }

    public mutating func reset() {
        samples.removeAll()
    }

    public mutating func snapshot(nowMicros: UInt64) -> Snapshot? {
        prune(nowMicros: nowMicros)
        guard samples.count >= Self.minimumSamples else { return nil }
        let arrivals = samples.map(\.arrival)
        let span = Double(arrivals[arrivals.count - 1] &- arrivals[0]) / 1_000_000
        let perSecond = span > 0 ? Double(samples.count - 1) / span : 0
        let gaps = zip(arrivals, arrivals.dropFirst()).map { Double($1 &- $0) / 1_000 }.sorted()

        var batchStarts: [UInt64] = [arrivals[0]]
        for (previous, current) in zip(arrivals, arrivals.dropFirst()) where current &- previous >= Self.batchGapMicros {
            batchStarts.append(current)
        }
        let batchGaps = zip(batchStarts, batchStarts.dropFirst()).map { Double($1 &- $0) / 1_000 }.sorted()
        let p50 = Self.percentile(gaps, 0.5)

        return Snapshot(
            packetsPerSecond: perSecond, arrivalP50Millis: p50, arrivalP95Millis: Self.percentile(gaps, 0.95),
            estimatedConnectionIntervalMillis: batchGaps.isEmpty ? p50 : Self.percentile(batchGaps, 0.5),
            backlogGrowthMillis: backlogGrowth())
    }

    /// Arrival time minus the phone's timeline since the newest stroke began.
    private func backlogGrowth() -> Double {
        var start = 0
        for index in samples.indices.dropFirst() where samples[index].arrival &- samples[index - 1].arrival > Self.strokeGapMicros {
            start = index
        }
        var timeline = 0.0
        for index in samples.indices.dropFirst(start + 1) { timeline += Double(samples[index].dtTenths) * 100 }
        let arrived = Double(samples[samples.count - 1].arrival &- samples[start].arrival)
        return (arrived - timeline) / 1_000
    }

    private mutating func prune(nowMicros: UInt64) {
        let cutoff = nowMicros > Self.windowMicros ? nowMicros - Self.windowMicros : 0
        if let firstKept = samples.firstIndex(where: { $0.arrival >= cutoff }) {
            samples.removeFirst(firstKept)
        } else {
            samples.removeAll()
        }
    }

    /// Nearest rank on a sorted list.
    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }
}
