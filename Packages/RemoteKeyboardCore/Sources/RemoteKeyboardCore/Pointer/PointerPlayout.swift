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
/// segment's own span plus `lagMarginMicros` (5 ms) when that is more: in 自動 one packet carries a whole connection interval, and
/// squeezing it below its own span would play it too fast and then stand still until the next one.
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
    /// How many times an `enqueue` squeezed the queue (a diagnostic counter; it changes nothing).
    public private(set) var squeezeCount = 0

    public init() {}

    /// Nothing is waiting to be played.
    public var isIdle: Bool { segments.isEmpty }

    /// - Parameter spanMicros: the time the finger took for this movement, from the packet; 0 when it did not say.
    public mutating func enqueue(dx: Double, dy: Double, dragging: Bool, spanMicros: UInt64, nowMicros: UInt64) {
        let span = spanMicros == 0 ? Self.defaultSpanMicros : min(max(spanMicros, Self.minSpanMicros), Self.maxSpanMicros)
        let now = Double(nowMicros)
        let start = segments.isEmpty ? now : max(now, lastEnd)
        let end = start + Double(span)
        segments.append(Segment(dx: dx, dy: dy, dragging: dragging, from: start, end: end))
        lastEnd = end
        let allowed = now + Double(max(Self.maxLagMicros, span + Self.lagMarginMicros))
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

    /// Forgets everything that has not been played.
    public mutating func discard() {
        segments.removeAll()
    }
}
