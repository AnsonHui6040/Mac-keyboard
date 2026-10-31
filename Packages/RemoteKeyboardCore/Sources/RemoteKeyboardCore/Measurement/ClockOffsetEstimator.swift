#if DEBUG
import Foundation

/// One round trip of an `rtt` probe, seen from both devices: when the iPhone handed the probe over, when the Mac says it
/// arrived (the Mac's clock), and when the reply reached the iPhone. The two clocks are never the same clock.
public struct ClockOffsetSample: Equatable, Sendable {
    public var phoneSendMicros: UInt64
    public var macRecvMicros: UInt64
    public var phoneRecvMicros: UInt64
    /// How long the Mac held the probe before it wrote the reply. It is part of the round trip but not of the delay.
    public var macHoldMicros: UInt64

    public init(phoneSendMicros: UInt64, macRecvMicros: UInt64, phoneRecvMicros: UInt64, macHoldMicros: UInt64 = 0) {
        self.phoneSendMicros = phoneSendMicros
        self.macRecvMicros = macRecvMicros
        self.phoneRecvMicros = phoneRecvMicros
        self.macHoldMicros = macHoldMicros
    }

    /// The round trip without the Mac's hold; `nil` for a sample that cannot be right (the reply arrived before the probe
    /// left, or the Mac held the probe longer than the whole round trip).
    var networkRttMicros: Double? {
        guard phoneRecvMicros >= phoneSendMicros else { return nil }
        let total = Double(phoneRecvMicros - phoneSendMicros)
        guard Double(macHoldMicros) <= total else { return nil }
        return total - Double(macHoldMicros)
    }
}

/// What the estimate rests on, the estimate itself, and how far off it can be: three separate things, never one number.
///
/// - `offsetEstimate`: Mac clock minus phone clock, in microseconds, at one phone time.
/// - `assumptions`: the delay is the same each way (that is an assumption, never measured) and how much the two clocks
///   drifted apart during the run, if the run was long enough to tell.
/// - `errorBound`: ± half the smallest round trip (with the symmetric assumption wrong by at most that much), plus what
///   the fitted line does not explain.
///
/// Every one-way number that comes out of this is an estimate and is labelled as one.
///
/// What the numbers contain and what they do not:
/// - The Mac's arrival time is taken when the main-actor handler of the Receiver starts, so the Mac's software delay between
///   the radio delivering the packet and that handler is part of the estimated one-way delay.
/// - `residualMicros` is a proxy for what the model leaves unexplained: the largest distance of any anchor from the drift line,
///   and the spread of the round trips that make up the main anchor. It is not a proven bound on the asymmetry.
/// - When the run is too short or too thin to measure a drift, `driftAllowanceMicros` adds 100 ppm over the span instead
///   (a conservative guess for the crystals involved, not a measurement); the assumption line then says `drift_measured=false`.
public struct ClockOffsetAnalysis: Equatable, Sendable {
    public struct OffsetEstimate: Equatable, Sendable {
        public let micros: Double
        public let atPhoneMicros: Double
    }

    public struct Assumptions: Equatable, Sendable {
        /// Always true: the way back is taken to be as long as the way there.
        public let symmetricDelay: Bool
        /// Change of (Mac clock − phone clock) per minute; 0 when `driftMeasured` is false.
        public let driftMicrosPerMinute: Double
        /// False when the run was too short (or had too few usable stretches) to tell a drift from noise.
        public let driftMeasured: Bool
        public let spanSeconds: Double
        public let sampleCount: Int
    }

    public struct ErrorBound: Equatable, Sendable {
        /// The smallest round trip among the samples, without the Mac's hold.
        public let minRttMicros: Double
        public let minRttHalfMicros: Double
        /// The largest distance of an anchor from the drift line, or of a round trip of the main anchor from it (proxy; see above).
        public let residualMicros: Double
        /// 100 ppm over the span when the drift could not be measured and the span is over 10 s; 0 otherwise.
        public let driftAllowanceMicros: Double
        public let totalMicros: Double
    }

    public let offsetEstimate: OffsetEstimate
    public let assumptions: Assumptions
    public let errorBound: ErrorBound
    /// The estimated one-way delay (iPhone hand-over to Mac arrival) of each usable input sample, in input order.
    public let estimatedOneWayMicros: [Double]
    /// The drift as microseconds of offset per microsecond of phone time (50 ppm is 0.00005).
    let slope: Double

    /// Mac clock minus phone clock at a phone time, with the measured drift applied.
    public func offsetMicros(atPhoneMicros phone: Double) -> Double {
        offsetEstimate.micros + slope * (phone - offsetEstimate.atPhoneMicros)
    }

    /// The estimated one-way delay of any packet whose phone send time and Mac arrival time are known.
    public func estimatedOneWayMicros(phoneSendMicros: UInt64, macRecvMicros: UInt64) -> Double {
        Double(macRecvMicros) - Double(phoneSendMicros) - offsetMicros(atPhoneMicros: Double(phoneSendMicros))
    }
}

public enum ClockOffsetEstimator {
    /// Below this distance between the first and last anchor the drift is not estimated.
    public static let minimumDriftSpanSeconds = 30.0
    /// Samples further apart than this belong to different clusters (M7 has a calibration at each end and nothing between).
    public static let clusterGapMicros: UInt64 = 20_000_000
    /// The anchor of a group is the median of this fraction of its lowest round trips (at least one sample).
    public static let anchorFraction = 0.05
    /// With no measured drift, a span over this many seconds gets the conservative allowance.
    public static let allowanceMinimumSpanSeconds = 10.0
    /// The allowance, as a drift rate (100 ppm).
    public static let allowancePpm = 100.0
    private static let driftBuckets = 10

    private struct Point {
        var sendMicros: UInt64
        var rtt: Double
        var mid: Double
        var offset: Double
    }

    private struct Anchor {
        var mid: Double
        var offset: Double
        var minRtt: Double
        /// The largest distance of the anchor's own samples from its median offset.
        var spread: Double
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// The median of the lowest `anchorFraction` of the round trips: one lucky sample does not decide it.
    private static func anchor(of group: [Point]) -> Anchor {
        let sorted = group.sorted { $0.rtt < $1.rtt }
        let count = max(1, Int((Double(sorted.count) * anchorFraction).rounded(.up)))
        let low = Array(sorted.prefix(count))
        let offset = median(low.map(\.offset))
        return Anchor(
            mid: median(low.map(\.mid)), offset: offset, minRtt: sorted[0].rtt,
            spread: low.map { abs($0.offset - offset) }.max() ?? 0)
    }

    /// Under the symmetric assumption each sample gives `offset = macRecv − (phoneSend + rtt/2)`. The smallest round trips
    /// leave the least room for asymmetry, so the line is anchored there. Its slope (the drift) comes from one anchor per
    /// cluster when the samples come in clusters far apart (two calibrations), otherwise from one anchor per tenth of the
    /// run, which keeps queueing delay out of the fit.
    public static func analyze(_ samples: [ClockOffsetSample]) -> ClockOffsetAnalysis? {
        let points: [Point] = samples.compactMap { sample in
            guard let rtt = sample.networkRttMicros else { return nil }
            let mid = Double(sample.phoneSendMicros) + rtt / 2
            return Point(sendMicros: sample.phoneSendMicros, rtt: rtt, mid: mid, offset: Double(sample.macRecvMicros) - mid)
        }
        guard !points.isEmpty else { return nil }
        let minRtt = points.map(\.rtt).min() ?? 0
        let ordered = points.sorted { $0.sendMicros < $1.sendMicros }
        let first = ordered[0].sendMicros
        let last = ordered[ordered.count - 1].sendMicros
        let spanSeconds = Double(last - first) / 1_000_000

        var clusters: [[Point]] = [[]]
        for (index, point) in ordered.enumerated() {
            if index > 0, point.sendMicros - ordered[index - 1].sendMicros > clusterGapMicros { clusters.append([]) }
            clusters[clusters.count - 1].append(point)
        }

        var fitAnchors: [Anchor] = []
        var mainAnchor = anchor(of: points)
        var minimumAnchors = 3
        if clusters.count >= 2 {
            fitAnchors = clusters.map(anchor(of:))
            if let best = fitAnchors.min(by: { $0.minRtt < $1.minRtt }) { mainAnchor = best }
            minimumAnchors = 2
        } else if spanSeconds >= minimumDriftSpanSeconds {
            let width = max(1.0, Double(last - first) / Double(driftBuckets))
            var buckets: [Int: [Point]] = [:]
            for point in ordered { buckets[min(driftBuckets - 1, Int(Double(point.sendMicros - first) / width)), default: []].append(point) }
            fitAnchors = buckets.values.map(anchor(of:))
        }

        var slope = 0.0
        var measured = false
        var residual = mainAnchor.spread
        if fitAnchors.count >= minimumAnchors {
            let anchors = fitAnchors.sorted { $0.mid < $1.mid }
            let separation = ((anchors.last?.mid ?? 0) - (anchors.first?.mid ?? 0)) / 1_000_000
            let meanX = anchors.reduce(0) { $0 + $1.mid } / Double(anchors.count)
            let meanY = anchors.reduce(0) { $0 + $1.offset } / Double(anchors.count)
            let denominator = anchors.reduce(0) { $0 + ($1.mid - meanX) * ($1.mid - meanX) }
            if separation >= minimumDriftSpanSeconds, denominator > 0 {
                slope = anchors.reduce(0) { $0 + ($1.mid - meanX) * ($1.offset - meanY) } / denominator
                measured = true
                residual = max(
                    residual, anchors.map { abs($0.offset - (mainAnchor.offset + slope * ($0.mid - mainAnchor.mid))) }.max() ?? 0)
            }
        }

        let allowance = !measured && spanSeconds > allowanceMinimumSpanSeconds ? spanSeconds * allowancePpm : 0
        let halfMin = minRtt / 2
        let estimate = ClockOffsetAnalysis.OffsetEstimate(micros: mainAnchor.offset, atPhoneMicros: mainAnchor.mid)
        let assumptions = ClockOffsetAnalysis.Assumptions(
            symmetricDelay: true, driftMicrosPerMinute: measured ? slope * 60_000_000 : 0, driftMeasured: measured,
            spanSeconds: spanSeconds, sampleCount: points.count)
        let bound = ClockOffsetAnalysis.ErrorBound(
            minRttMicros: minRtt, minRttHalfMicros: halfMin, residualMicros: residual, driftAllowanceMicros: allowance,
            totalMicros: halfMin + residual + allowance)
        let model = ClockOffsetAnalysis(
            offsetEstimate: estimate, assumptions: assumptions, errorBound: bound, estimatedOneWayMicros: [], slope: slope)
        let oneWay = samples.compactMap { sample -> Double? in
            guard sample.networkRttMicros != nil else { return nil }
            return model.estimatedOneWayMicros(phoneSendMicros: sample.phoneSendMicros, macRecvMicros: sample.macRecvMicros)
        }
        return ClockOffsetAnalysis(
            offsetEstimate: estimate, assumptions: assumptions, errorBound: bound, estimatedOneWayMicros: oneWay, slope: slope)
    }
}
#endif
