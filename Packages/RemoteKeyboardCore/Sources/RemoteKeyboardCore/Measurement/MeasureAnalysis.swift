#if DEBUG
import Foundation

/// One row of the Mac's measurement CSV. Numbers and a kind name only: no typed text, no cursor position, no `dx`.
///
/// `holdMicros` is how long the Mac held an `rtt` probe before it wrote the reply, -1 when the probe was not answered and 0
/// for the other kinds. `counterGap` is the number of packets between this one and the one before it that never arrived.
/// `phoneTimeMicros` is the iPhone's clock as the probe carried it (0 for the long-text rows); `macTimeMicros` is the Mac's
/// clock when the row's packet (or long text) arrived.
public struct MeasureCSVRecord: Equatable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case burst, rtt, cursor, heartbeat
        /// The long text arrived whole (length and SHA-256 match).
        case longTextMatch
        /// A long text arrived but length or SHA-256 differ.
        case longTextMismatch

        public init(_ payloadKind: MeasurePayload.Kind) {
            switch payloadKind {
            case .burst: self = .burst
            case .rtt: self = .rtt
            case .cursor: self = .cursor
            case .heartbeat: self = .heartbeat
            }
        }

        var isProbe: Bool { self != .longTextMatch && self != .longTextMismatch }
    }

    public static let header = "seq,kind,bytes,counterGap,interArrivalMicros,holdMicros,phoneTimeMicros,macTimeMicros"

    public var seq: UInt32
    public var kind: Kind
    public var bytes: Int
    public var counterGap: Int
    public var interArrivalMicros: Int
    public var holdMicros: Int
    public var phoneTimeMicros: UInt64
    public var macTimeMicros: UInt64

    public init(
        seq: UInt32, kind: Kind, bytes: Int, counterGap: Int, interArrivalMicros: Int, holdMicros: Int,
        phoneTimeMicros: UInt64, macTimeMicros: UInt64
    ) {
        self.seq = seq
        self.kind = kind
        self.bytes = bytes
        self.counterGap = counterGap
        self.interArrivalMicros = interArrivalMicros
        self.holdMicros = holdMicros
        self.phoneTimeMicros = phoneTimeMicros
        self.macTimeMicros = macTimeMicros
    }

    public var line: String {
        "\(seq),\(kind.rawValue),\(bytes),\(counterGap),\(interArrivalMicros),\(holdMicros),\(phoneTimeMicros),\(macTimeMicros)"
    }

    public init?(line: String) {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 8, let seq = UInt32(fields[0]), let kind = Kind(rawValue: String(fields[1])),
              let bytes = Int(fields[2]), let gap = Int(fields[3]), let inter = Int(fields[4]), let hold = Int(fields[5]),
              let phone = UInt64(fields[6]), let mac = UInt64(fields[7])
        else { return nil }
        self.init(
            seq: seq, kind: kind, bytes: bytes, counterGap: gap, interArrivalMicros: inter, holdMicros: hold,
            phoneTimeMicros: phone, macTimeMicros: mac)
    }

    /// The file holds several runs one after the other; a run starts where the probe seq goes back. Long-text rows have no seq
    /// of their own and stay in the run in which they arrived.
    public static func runs(in rows: [MeasureCSVRecord]) -> [[MeasureCSVRecord]] {
        var runs: [[MeasureCSVRecord]] = []
        var lastSeq: UInt32?
        for row in rows {
            if row.kind.isProbe {
                if runs.isEmpty || (lastSeq.map { row.seq < $0 } ?? false) { runs.append([]) }
                lastSeq = row.seq
            } else if runs.isEmpty {
                runs.append([])
            }
            runs[runs.count - 1].append(row)
        }
        return runs
    }
}

/// Anything that can say what (Mac clock − phone clock) was at a phone time.
public protocol ClockOffsetModelling {
    func offsetMicros(atPhoneMicros phone: Double) -> Double
}

extension ClockOffsetAnalysis: ClockOffsetModelling {}

/// The clock model as the iPhone printed it on its `M3c` or `CAL` line (`offset_est_us`, `ref_phone_us`, `drift_us_per_min`),
/// so the numbers of a run can be combined with the Mac's CSV afterwards.
public struct ClockOffsetModel: ClockOffsetModelling, Equatable, Sendable {
    public let offsetMicros: Double
    public let referencePhoneMicros: Double
    public let driftMicrosPerMinute: Double

    public init?(parsing line: String) {
        var values: [String: Double] = [:]
        for part in line.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2, let number = Double(pair[1]) { values[String(pair[0])] = number }
        }
        guard let offset = values["offset_est_us"], let reference = values["ref_phone_us"] else { return nil }
        offsetMicros = offset
        referencePhoneMicros = reference
        driftMicrosPerMinute = values["drift_us_per_min"] ?? 0
    }

    public func offsetMicros(atPhoneMicros phone: Double) -> Double {
        offsetMicros + driftMicrosPerMinute / 60_000_000 * (phone - referencePhoneMicros)
    }
}

public enum OneWayAnalysis {
    /// Estimated one-way delay in milliseconds of the Mac rows of one kind, optionally only those of a seq range: the Mac's
    /// arrival time minus the phone's send time minus the estimated clock offset. An estimate, with the model's error bound.
    public static func estimatedOneWayMs(
        rows: [MeasureCSVRecord], kind: MeasureCSVRecord.Kind, seqRange: ClosedRange<UInt32>?, using model: some ClockOffsetModelling
    ) -> [Double] {
        rows.filter { $0.kind == kind && (seqRange?.contains($0.seq) ?? true) }.map { row in
            (Double(row.macTimeMicros) - Double(row.phoneTimeMicros) - model.offsetMicros(atPhoneMicros: Double(row.phoneTimeMicros))) / 1000
        }
    }
}

/// M6 and M8: heartbeat gaps that the real 350 ms watchdog would have released a button on. Nothing is released.
public enum SimulatedRelease {
    public static let watchdogMicros: UInt64 = 350_000

    public struct Result: Equatable, Sendable {
        public let count: Int
        public let maxGapMicros: UInt64
        public let gaps: Int
    }

    /// Consecutive heartbeats of one series; a seq that goes back starts a new series, whose first heartbeat has no gap.
    public static func count(in rows: [MeasureCSVRecord]) -> Result {
        var previous: MeasureCSVRecord?
        var count = 0
        var gaps = 0
        var maxGap: UInt64 = 0
        for row in rows where row.kind == .heartbeat {
            defer { previous = row }
            guard let last = previous, row.seq > last.seq, row.macTimeMicros >= last.macTimeMicros else { continue }
            let gap = row.macTimeMicros - last.macTimeMicros
            gaps += 1
            maxGap = max(maxGap, gap)
            if gap > watchdogMicros { count += 1 }
        }
        return Result(count: count, maxGapMicros: maxGap, gaps: gaps)
    }
}

/// Evidence that a connection latency request changed anything: the median gap between arrivals at the Mac in the 5 s before
/// the request and in the 5 s that start 2 s after it. Only the `burst` rows the run sends for this purpose count. This is
/// supporting evidence, not confirmation; only PacketLogger confirms the interval.
public enum ArrivalShift {
    public struct Result: Equatable, Sendable {
        public let beforeMedianMs: Double
        public let afterMedianMs: Double
        public let beforeCount: Int
        public let afterCount: Int
        public var changeMs: Double { afterMedianMs - beforeMedianMs }
    }

    public static func measure(rows: [MeasureCSVRecord], requestPhoneMicros: UInt64) -> Result {
        let window = UInt64(MeasureLatencyPreference.evidenceWindowSeconds) * 1_000_000
        let settle = UInt64(MeasureLatencyPreference.settleSeconds) * 1_000_000
        let bursts = rows.filter { $0.kind == .burst && $0.interArrivalMicros > 0 }
        let before = bursts.filter { $0.phoneTimeMicros + window >= requestPhoneMicros && $0.phoneTimeMicros < requestPhoneMicros }
        let after = bursts.filter {
            $0.phoneTimeMicros >= requestPhoneMicros + settle && $0.phoneTimeMicros < requestPhoneMicros + settle + window
        }
        func median(_ rows: [MeasureCSVRecord]) -> Double {
            rows.isEmpty ? .nan : LatencyStats(samplesMs: rows.map { Double($0.interArrivalMicros) / 1000 }).p50
        }
        return Result(beforeMedianMs: median(before), afterMedianMs: median(after), beforeCount: before.count, afterCount: after.count)
    }
}

/// M7's condition (spec §13.4): the first cursor packet after the switch may not be slower than twice the P99 of the same
/// round's baseline (both are estimated one-way delays).
public enum ModeSwitchVerdict {
    public static func passes(baselineMs: [Double], firstAfterMs: Double) -> Bool {
        guard !baselineMs.isEmpty, firstAfterMs.isFinite else { return false }
        return firstAfterMs <= LatencyStats(samplesMs: baselineMs).p99 * 2
    }
}
#endif
