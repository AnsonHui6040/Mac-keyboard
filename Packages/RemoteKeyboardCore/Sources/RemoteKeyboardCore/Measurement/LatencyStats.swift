import Foundation

/// Percentiles of a list of durations in milliseconds, with linear interpolation between ranks (`rank = p × (n − 1)`).
/// An empty list has count 0 and `.nan` everywhere.
public struct LatencyStats: Equatable, Sendable {
    public let count: Int
    public let p50: Double
    public let p95: Double
    public let p99: Double
    public let meanMs: Double
    public let maxMs: Double
    /// Population standard deviation.
    public let standardDeviationMs: Double

    public init(samplesMs: [Double]) {
        count = samplesMs.count
        guard !samplesMs.isEmpty else {
            (p50, p95, p99, meanMs, maxMs, standardDeviationMs) = (.nan, .nan, .nan, .nan, .nan, .nan)
            return
        }
        let sorted = samplesMs.sorted()
        func percentile(_ p: Double) -> Double {
            let rank = p * Double(sorted.count - 1)
            let low = Int(rank.rounded(.down))
            let high = min(low + 1, sorted.count - 1)
            return sorted[low] + (rank - Double(low)) * (sorted[high] - sorted[low])
        }
        p50 = percentile(0.50)
        p95 = percentile(0.95)
        p99 = percentile(0.99)
        let mean = sorted.reduce(0, +) / Double(sorted.count)
        meanMs = mean
        maxMs = sorted[sorted.count - 1]
        standardDeviationMs = (sorted.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(sorted.count)).squareRoot()
    }

    /// `p95 − p50`.
    public var jitterMs: Double { p95 - p50 }
}
