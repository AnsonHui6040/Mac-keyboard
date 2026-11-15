import Foundation

/// Spreads the cursor movement of received MOVE packets over time, so the cursor glides instead of jumping when the radio
/// delivers packets in bunches. Pure logic; time is passed in and the caller asks for a share once per screen refresh.
///
/// Each `enqueue` becomes a **segment**: its displacement is played out evenly over the time span the phone measured for it
/// (clamped to 4…50 ms; none given means 8 ms). A segment starts at `now`, or where the previous one ends when that is later,
/// so two packets that arrive together play one after the other and not on top of each other.
///
/// The queue never grows a delay without bound: when the last segment would end more than the allowed lag after `now`, what is
/// still to be played is squeezed so that it ends exactly that far ahead. The allowed lag is `maxLagMicros` (20 ms), or the new
/// segment's own span plus `lagMarginMicros` (5 ms) when that is more, or the measured arrival period plus 5 ms when that is
/// more (capped at `maxAdaptiveLagMicros`, 60 ms): in 自動 one packet carries a whole connection interval, and squeezing it
/// below its own span would play it too fast and then stand still until the next one. The arrival period is the median of the
/// last 8 gaps between burst starts: an enqueue more than 4 ms after the previous one opens a burst, and a gap between burst
/// starts counts when it is at most 100 ms (a longer one is a pause; one over 300 ms also forgets the history). A link that
/// delivers 3 packets every 45 ms thus gets a 50 ms bound instead of a 22 ms one and the cursor does not stop between
/// bursts, while a link with one packet per 15 ms keeps the 20 ms bound.
///
/// `take` hands out what has become due. Movements with a different `dragging` state are never added into one output, so a
/// button press in between keeps its place. `flush` hands out everything left at once (the order barrier before a click),
/// `discard` drops it (the channel is over). Nothing leaves in any other way, so the displacement that went in is the displacement
/// that comes out, up to floating point rounding.
public struct PointerPlayout: Sendable {
    /// The lag floor: the cursor does not trail the packets by more than this, or by the newest packet's span plus the margin if that is more. Provisional until measured on a device.
    public static let maxLagMicros: UInt64 = 20_000
    public static let minSpanMicros: UInt64 = 4_000
    /// Provisional, like `maxLagMicros`.
    public static let maxSpanMicros: UInt64 = 50_000
    /// Added to a segment's own span for the lag bound. Provisional.
    public static let lagMarginMicros: UInt64 = 5_000
    public static let defaultSpanMicros: UInt64 = 8_000
    /// The cap of the part of the lag bound that follows the arrival period. Provisional.
    public static let maxAdaptiveLagMicros: UInt64 = 60_000
    /// An enqueue this much later than the one before opens a new burst.
    public static let burstGapMicros: UInt64 = 4_000
    /// A gap between burst starts longer than this is a pause and is not counted.
    public static let maxPeriodGapMicros: UInt64 = 100_000
    /// A gap between burst starts longer than this also forgets the history.
    public static let forgetGapMicros: UInt64 = 300_000
    /// How many gaps the estimate looks at.
    public static let periodHistory = 8

    private struct Segment {
        /// What is still to be played, spread evenly over `from`…`end`.
        var dx: Double
        var dy: Double
        let dragging: Bool
        var from: Double
        var end: Double
    }

    private var segments: [Segment] = []
    private var lastEnd: Double = 0
    /// When the last `enqueue` happened.
    private var lastEnqueue: UInt64?
    /// When the burst that is going started.
    private var burstStart: UInt64?
    /// The latest gaps between burst starts, oldest first.
    private var gaps: [UInt64] = []
    /// The lag bound the last `enqueue` used; 0 before the first one.
    private var lagBound: UInt64 = 0
    /// How many times an `enqueue` squeezed the queue (a diagnostic counter; it changes nothing).
    public private(set) var squeezeCount = 0

    public init() {}

    /// The lag bound the last `enqueue` allowed, in microseconds (the floor before the first one; a diagnostic).
    public var lagBoundMicros: UInt64 { lagBound == 0 ? Self.maxLagMicros : lagBound }

    /// Nothing is waiting to be played.
    public var isIdle: Bool { segments.isEmpty }

    /// Notes an arrival: opens a burst when it comes more than `burstGapMicros` after the previous one and then records the
    /// gap between burst starts.
    private mutating func noteArrival(nowMicros: UInt64) {
        let newBurst = lastEnqueue.map { nowMicros.saturatingSubtract($0) > Self.burstGapMicros } ?? true
        lastEnqueue = nowMicros
        guard newBurst else { return }
        if let start = burstStart {
            let gap = nowMicros.saturatingSubtract(start)
            if gap > Self.forgetGapMicros {
                gaps.removeAll()
            } else if gap <= Self.maxPeriodGapMicros {
                if gaps.count == Self.periodHistory { gaps.removeFirst() }
                gaps.append(gap)
            }
        }
        burstStart = nowMicros
    }

    /// The median of the recorded gaps between burst starts; `nil` while there are none.
    private var arrivalPeriod: UInt64? {
        guard !gaps.isEmpty else { return nil }
        return gaps.sorted()[gaps.count / 2]
    }

    /// - Parameter spanMicros: the time the finger took for this movement, from the packet; 0 when it did not say.
    public mutating func enqueue(dx: Double, dy: Double, dragging: Bool, spanMicros: UInt64, nowMicros: UInt64) {
        let span = spanMicros == 0 ? Self.defaultSpanMicros : min(max(spanMicros, Self.minSpanMicros), Self.maxSpanMicros)
        let now = Double(nowMicros)
        let start = segments.isEmpty ? now : max(now, lastEnd)
        let end = start + Double(span)
        segments.append(Segment(dx: dx, dy: dy, dragging: dragging, from: start, end: end))
        lastEnd = end
        noteArrival(nowMicros: nowMicros)
        let adaptive = arrivalPeriod.map { min($0 + Self.lagMarginMicros, Self.maxAdaptiveLagMicros) } ?? 0
        lagBound = max(Self.maxLagMicros, span + Self.lagMarginMicros, adaptive)
        let allowed = now + Double(lagBound)
        guard lastEnd > allowed else { return }
        squeezeCount += 1
        // Squeeze the part that lies after `now`; what is already behind `now` stays where it is.
        let factor = (allowed - now) / (lastEnd - now)
        func squeezed(_ t: Double) -> Double { t > now ? now + (t - now) * factor : t }
        for index in segments.indices {
            segments[index].from = squeezed(segments[index].from)
            segments[index].end = squeezed(segments[index].end)
        }
        lastEnd = allowed
    }

    /// What is due up to `now`, or `nil` when no segment has moved on. When the next segment has another `dragging` state the
    /// result stops short of it; ask again for the rest.
    public mutating func take(nowMicros: UInt64) -> (dx: Double, dy: Double, dragging: Bool)? {
        let now = Double(nowMicros)
        var sum: (dx: Double, dy: Double, dragging: Bool)?
        var finished = 0
        for index in segments.indices {
            let segment = segments[index]
            if let current = sum, current.dragging != segment.dragging { break }
            let until = min(now, segment.end)
            guard until > segment.from else { break }
            let share = until >= segment.end ? 1 : (until - segment.from) / (segment.end - segment.from)
            let dx = share == 1 ? segment.dx : segment.dx * share
            let dy = share == 1 ? segment.dy : segment.dy * share
            sum = (((sum?.dx ?? 0) + dx), ((sum?.dy ?? 0) + dy), segment.dragging)
            if share == 1 {
                finished += 1
            } else {
                segments[index].dx -= dx
                segments[index].dy -= dy
                segments[index].from = until
                break
            }
        }
        segments.removeFirst(finished)
        return sum
    }

    /// Everything still to be played, now, as one output per run of the same `dragging` state.
    public mutating func flush() -> [(dx: Double, dy: Double, dragging: Bool)] {
        var runs: [(dx: Double, dy: Double, dragging: Bool)] = []
        for segment in segments {
            if let last = runs.last, last.dragging == segment.dragging {
                runs[runs.count - 1] = (last.dx + segment.dx, last.dy + segment.dy, last.dragging)
            } else {
                runs.append((segment.dx, segment.dy, segment.dragging))
            }
        }
        segments.removeAll()
        return runs
    }

    /// Forgets everything that has not been played, and the arrival history.
    public mutating func discard() {
        segments.removeAll()
        lastEnqueue = nil
        burstStart = nil
        gaps.removeAll()
        lagBound = 0
    }
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}
