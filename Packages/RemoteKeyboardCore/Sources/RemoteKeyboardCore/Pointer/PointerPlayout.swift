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
    /// The lag floor: the cursor does not trail the packets by more than this, or by the newest packet's span plus the margin if that is more. Fixed by the trackpad feel baseline (docs/superpowers/specs/2026-11-17-trackpad-feel-baseline.md).
    public static let maxLagMicros: UInt64 = 20_000
    public static let minSpanMicros: UInt64 = 4_000
    /// Fixed by the trackpad feel baseline (docs/superpowers/specs/2026-11-17-trackpad-feel-baseline.md).
    public static let maxSpanMicros: UInt64 = 50_000
    /// Added to a segment's own span for the lag bound. Fixed by the trackpad feel baseline (docs/superpowers/specs/2026-11-17-trackpad-feel-baseline.md).
    public static let lagMarginMicros: UInt64 = 5_000
    public static let defaultSpanMicros: UInt64 = 8_000
    /// The cap of the part of the lag bound that follows the arrival period. Fixed by the trackpad feel baseline (docs/superpowers/specs/2026-11-17-trackpad-feel-baseline.md).
    public static let maxAdaptiveLagMicros: UInt64 = 60_000
    /// An enqueue this much later than the one before opens a new burst.
    public static let burstGapMicros: UInt64 = 4_000
    /// A gap between burst starts longer than this is a pause and is not counted.
    public static let maxPeriodGapMicros: UInt64 = 100_000
    /// A gap between burst starts longer than this also forgets the history.
    public static let forgetGapMicros: UInt64 = 300_000
    /// How many gaps the estimate looks at.
    public static let periodHistory = 8
    /// The most start delay the jitter allowance can reach. Fixed by the trackpad feel baseline (docs/superpowers/specs/2026-11-17-trackpad-feel-baseline.md).
    public static let maxJitterMicros: UInt64 = 80_000
    /// The time in which the jitter allowance halves when the link is clean. Fixed by the trackpad feel baseline (docs/superpowers/specs/2026-11-17-trackpad-feel-baseline.md).
    public static let jitterDecayHalfLifeMicros: UInt64 = 5_000_000
    /// An allowance below this becomes 0. Fixed by the trackpad feel baseline (docs/superpowers/specs/2026-11-17-trackpad-feel-baseline.md).
    public static let jitterFloorMicros: UInt64 = 5_000
    /// While the buffer is shorter than the allowance a segment plays this much slower to rebuild it. After a pause that can
    /// last a few hundred milliseconds (the buffer refills by a quarter of each segment's span). Fixed by the trackpad feel baseline (docs/superpowers/specs/2026-11-17-trackpad-feel-baseline.md).
    public static let refillStretch: Double = 1.25
    /// An arrival gap this much longer than the usual arrival period (and over twice that period) is a radio pause. Fixed by the trackpad feel baseline (docs/superpowers/specs/2026-11-17-trackpad-feel-baseline.md).
    public static let pauseThresholdMicros: UInt64 = 20_000
    /// This many pause-sized gaps in a row are taken as a new arrival period, not as pauses. Fixed by the trackpad feel baseline (docs/superpowers/specs/2026-11-17-trackpad-feel-baseline.md).
    public static let pausesBeforeRelearning = 3
    /// An enqueue within this time after the previous one belongs to the same stroke. Fixed by the trackpad feel baseline (docs/superpowers/specs/2026-11-17-trackpad-feel-baseline.md).
    public static let strokeGapMicros: UInt64 = 100_000

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
    /// How many arrivals in a row were pauses.
    private var consecutivePauses = 0
    /// The jitter allowance in microseconds and when it was last brought up to date.
    private var jitterAllowance: Double = 0
    private var lastJitterUpdate: UInt64?
    /// How many times an `enqueue` squeezed the queue (a diagnostic counter; it changes nothing).
    public private(set) var squeezeCount = 0

    /// How many times the queue had run dry in the middle of a stroke when a packet arrived (a diagnostic; it changes nothing).
    public private(set) var underrunCount = 0
    /// How many radio pauses (arrival gaps well beyond the usual period) were seen in the middle of a stroke.
    public private(set) var pauseCount = 0

    /// The start delay a new stroke gets, in microseconds; grows with observed mid-stroke pauses and decays on a clean link.
    public var jitterAllowanceMicros: UInt64 { UInt64(jitterAllowance.rounded()) }

    public init() {}

    /// The lag bound the last `enqueue` allowed, in microseconds (the floor before the first one; a diagnostic).
    public var lagBoundMicros: UInt64 { lagBound == 0 ? Self.maxLagMicros : lagBound }

    /// When the last segment ends (after any squeeze), in microseconds; 0 before the first `enqueue`. Once this is in the past
    /// the queue has run out (a diagnostic).
    public var lastSegmentEndMicros: UInt64 { lastEnd > 0 ? UInt64(lastEnd) : 0 }

    /// Nothing is waiting to be played.
    public var isIdle: Bool { segments.isEmpty }

    /// Notes an arrival: opens a burst when it comes more than `burstGapMicros` after the previous one and then records the
    /// gap between burst starts (unless the arrival ends a radio pause: that gap says nothing about the usual period).
    private mutating func noteArrival(nowMicros: UInt64, endsPause: Bool) {
        let newBurst = lastEnqueue.map { nowMicros.saturatingSubtract($0) > Self.burstGapMicros } ?? true
        lastEnqueue = nowMicros
        guard newBurst else { return }
        if let start = burstStart {
            let gap = nowMicros.saturatingSubtract(start)
            if gap > Self.forgetGapMicros {
                gaps.removeAll()
            } else if gap <= Self.maxPeriodGapMicros && !endsPause {
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

    /// Lets the allowance halve every `jitterDecayHalfLifeMicros` since it was last brought up to date; below the floor it is 0.
    private mutating func decayAllowance(nowMicros: UInt64) {
        defer { lastJitterUpdate = nowMicros }
        guard jitterAllowance > 0, let last = lastJitterUpdate else { return }
        let elapsed = Double(nowMicros.saturatingSubtract(last))
        jitterAllowance *= pow(0.5, elapsed / Double(Self.jitterDecayHalfLifeMicros))
        if jitterAllowance < Double(Self.jitterFloorMicros) { jitterAllowance = 0 }
    }

    /// Counts a pause in a row. Pauses are kept out of the arrival history, but this many in a row is no pause any more: the
    /// link changed its interval (a renegotiated connection), so the history starts again from the new gaps. Returns whether
    /// the arrival still counts as a pause for the history.
    private mutating func settlePauseRun(isPause: Bool) -> Bool {
        guard isPause else { consecutivePauses = 0; return false }
        consecutivePauses += 1
        guard consecutivePauses >= Self.pausesBeforeRelearning else { return true }
        consecutivePauses = 0
        gaps.removeAll()
        return false
    }

    /// A packet came much later than the usual period (more than the threshold and more than one missed slot; with no period measured yet nothing counts as a pause): the allowance must cover the excess plus the margin.
    private mutating func notePauseIfAny(gap: UInt64) -> Bool {
        guard let period = arrivalPeriod, gap > max(period + Self.pauseThresholdMicros, 2 * period) else { return false }
        pauseCount += 1
        let wanted = Double(gap - period + Self.lagMarginMicros)
        jitterAllowance = min(Double(Self.maxJitterMicros), max(jitterAllowance, wanted))
        return true
    }

    /// - Parameter spanMicros: the time the finger took for this movement, from the packet; 0 when it did not say.
    public mutating func enqueue(dx: Double, dy: Double, dragging: Bool, spanMicros: UInt64, nowMicros: UInt64) {
        let now = Double(nowMicros)
        decayAllowance(nowMicros: nowMicros)
        var isPause = false
        let inStroke = lastEnqueue.map { nowMicros.saturatingSubtract($0) <= Self.strokeGapMicros } ?? false
        if inStroke && lastEnd > 0 && lastEnd < now { underrunCount += 1 }
        if inStroke, let previous = lastEnqueue { isPause = notePauseIfAny(gap: nowMicros.saturatingSubtract(previous)) }
        let depth = max(0, lastEnd - now)
        let startsStroke = segments.isEmpty && !inStroke
        let start = segments.isEmpty ? now + (startsStroke ? jitterAllowance : 0) : max(now, lastEnd)
        let ownSpan = spanMicros == 0 ? Self.defaultSpanMicros : min(max(spanMicros, Self.minSpanMicros), Self.maxSpanMicros)
        let refilling = jitterAllowance > 0 && depth < jitterAllowance
        let span = refilling ? UInt64((Double(ownSpan) * Self.refillStretch).rounded()) : ownSpan
        let end = start + Double(span)
        segments.append(Segment(dx: dx, dy: dy, dragging: dragging, from: start, end: end))
        lastEnd = end
        noteArrival(nowMicros: nowMicros, endsPause: settlePauseRun(isPause: isPause))
        let adaptive = arrivalPeriod.map { min($0 + Self.lagMarginMicros, Self.maxAdaptiveLagMicros) } ?? 0
        let buffered = jitterAllowanceMicros + span + Self.lagMarginMicros
        let cap = Self.maxJitterMicros + Self.maxSpanMicros + Self.lagMarginMicros
        lagBound = min(cap, max(Self.maxLagMicros, span + Self.lagMarginMicros, adaptive, buffered))
        squeezeToLagBound(now: now)
    }

    /// When the last segment would end later than the lag bound allows, squeezes what lies after `now` so that it ends exactly there.
    private mutating func squeezeToLagBound(now: Double) {
        let allowed = now + Double(lagBound)
        guard lastEnd > allowed else { return }
        squeezeCount += 1
        // What is already behind `now` stays where it is.
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
        lastEnd = 0  // nothing is queued any more: the next segment sees an empty buffer, not a stale end time
        return runs
    }

    /// Forgets everything that has not been played, the arrival history and the jitter allowance (the channel is over).
    public mutating func discard() {
        segments.removeAll()
        lastEnd = 0
        consecutivePauses = 0
        jitterAllowance = 0
        lastJitterUpdate = nil
        lastEnqueue = nil
        burstStart = nil
        gaps.removeAll()
        lagBound = 0
    }
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 { self > other ? self - other : 0 }
}
