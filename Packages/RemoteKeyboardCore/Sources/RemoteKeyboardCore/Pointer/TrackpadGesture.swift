import Foundation

/// One finger sample on the pad, in points of the pad view. `id` is stable while the finger is down; `timeMicros` is on the
/// clock of `PointerClock`.
public struct TrackpadTouch: Equatable, Sendable {
    public let id: Int
    public let x: Double
    public let y: Double
    public let timeMicros: UInt64

    public init(id: Int, x: Double, y: Double, timeMicros: UInt64) {
        self.id = id
        self.x = x
        self.y = y
        self.timeMicros = timeMicros
    }
}

/// What the touchpad does, in terms the `PointerSender` takes. Movements are in iPhone points.
public enum TrackpadOutput: Equatable, Sendable {
    case strokeBegan(timeMicros: UInt64)
    case move(dx: Double, dy: Double, timeMicros: UInt64)
    /// `count` is 2 for the second tap of a double click.
    case click(count: Int, timeMicros: UInt64)
    case rightClick(timeMicros: UInt64)
    case buttonDown(timeMicros: UInt64)
    case buttonUp(timeMicros: UInt64)
    case scrollBegan(timeMicros: UInt64)
    case scroll(dx: Double, dy: Double, timeMicros: UInt64)
    case scrollEnded(timeMicros: UInt64)
}

/// Reads finger samples into the touchpad gestures (trackpad spec §9, MVP subset). Pure: no clock, no timer; a long press
/// is found by the caller's regular `tick`.
///
/// - One finger that stays within 8 pt and lifts within 200 ms is a click. A second such tap within 500 ms and 12 pt of the
///   first one's lift is a click with count 2 (a double click); the next tap starts over at 1. A move, drag, scroll,
///   two-finger gesture or cancel in between forgets the first tap.
/// - Tap, then press and hold to drag: a finger that lands within 500 ms and 12 pt of a tap's lift is a second press. If it
///   lifts within 200 ms and 8 pt it is the double click above; if it stays down past 200 ms, or moves beyond 8 pt first, the
///   left button goes down (with the whole distance so far) and it is a drag. The first tap's click has already gone out,
///   and no double click is sent for that press. The next tap after the drag starts over at 1.
/// - Two fingers that tap (the centre stays within 8 pt, each finger within 12 pt of where it landed, and the last lift comes
///   within 300 ms of the first finger down) are a right click, sent when the last finger lifts.
/// - One finger that stays within 8 pt for 400 ms starts a drag: the left button goes down, every later movement is sent at
///   once, and lifting the finger releases the button.
/// - One finger that goes beyond 8 pt moves the cursor. Up to then the movement is held back (so a tap does not nudge the
///   cursor); when the threshold is passed, the whole distance so far goes out at once and then every movement as it comes.
/// - Two fingers whose centre travels more than 8 pt scroll, with the same catch-up; lifting either finger ends the scroll.
/// - A finger that lands once another one is already moving or dragging is ignored. After a scroll ends, the remaining
///   finger is ignored until every finger has lifted.
/// - A cancelled touch releases a drag and ends a scroll, and never clicks.
public struct TrackpadGesture: Sendable {
    public static let tapMaxMicros: UInt64 = 200_000
    public static let longPressMicros: UInt64 = 400_000
    public static let travelThreshold = 8.0
    public static let doubleTapMaxMicros: UInt64 = 500_000
    public static let doubleTapMaxDistance = 12.0
    public static let twoFingerTapMaxMicros: UInt64 = 300_000
    public static let twoFingerTapMaxTravel = 12.0

    private struct Point: Sendable {
        var x: Double
        var y: Double
    }

    private enum Phase: Sendable {
        case idle
        /// One finger, not yet moved beyond the threshold. `second` is true for a press that landed soon enough after a tap to
        /// become a tap-drag.
        case pending(id: Int, origin: Point, startedAt: UInt64, second: Bool)
        case moving(id: Int, last: Point)
        case dragging(id: Int, last: Point)
        /// Two fingers, centre not yet past the threshold. `tap` stays true while the pair could still be a two-finger tap.
        case twoPending(a: Int, b: Int, origin: Point, landedA: Point, landedB: Point, startedAt: UInt64, tap: Bool)
        /// A two-finger tap with one finger already lifted; the right click goes when this one lifts.
        case twoLifting(id: Int, landed: Point, startedAt: UInt64)
        case scrolling(a: Int, b: Int, last: Point)
        /// Fingers are down and mean nothing until all of them have lifted.
        case ignoring
    }

    private var phase = Phase.idle
    private var fingers: [Int: Point] = [:]
    /// Where and when the last tap lifted, while a second tap could still make it a double click.
    private var lastTap: (point: Point, time: UInt64)?

    public init() {}

    public var isIdle: Bool {
        if case .idle = phase { return fingers.isEmpty }
        return false
    }

    // MARK: Touches

    public mutating func touchesBegan(_ touches: [TrackpadTouch]) -> [TrackpadOutput] {
        for touch in touches { fingers[touch.id] = Point(x: touch.x, y: touch.y) }
        switch phase {
        case .idle:
            if fingers.count == 1, let touch = touches.first {
                let origin = Point(x: touch.x, y: touch.y)
                let second = lastTap.map {
                    touch.timeMicros &- $0.time <= Self.doubleTapMaxMicros
                        && hypot(origin.x - $0.point.x, origin.y - $0.point.y) <= Self.doubleTapMaxDistance
                } ?? false
                phase = .pending(id: touch.id, origin: origin, startedAt: touch.timeMicros, second: second)
                return [.strokeBegan(timeMicros: touch.timeMicros)]
            }
            // Two fingers down together are a pair from the start; more than two mean nothing.
            let ids = fingers.keys.sorted()
            if ids.count == 2, let first = fingers[ids[0]], let second = fingers[ids[1]], let time = touches.map(\.timeMicros).min() {
                lastTap = nil
                phase = .twoPending(
                    a: ids[0], b: ids[1], origin: Self.centre(first, second), landedA: first, landedB: second, startedAt: time,
                    tap: true)
            } else {
                phase = .ignoring
            }
        case .pending(let id, _, let startedAt, _):
            // The second finger of a two-finger gesture: the first has not moved beyond the threshold, so the two start together.
            let others = fingers.keys.filter { $0 != id }
            lastTap = nil
            if others.count == 1, let first = fingers[id], let second = fingers[others[0]] {
                phase = .twoPending(
                    a: id, b: others[0], origin: Self.centre(first, second), landedA: first, landedB: second, startedAt: startedAt,
                    tap: true)
            } else {
                phase = .ignoring
            }
        case .twoPending(let a, let b, let origin, let landedA, let landedB, let startedAt, _):
            // A third finger: still a pair for scrolling, but no longer a tap.
            phase = .twoPending(a: a, b: b, origin: origin, landedA: landedA, landedB: landedB, startedAt: startedAt, tap: false)
        case .twoLifting:
            phase = .ignoring
        case .moving, .dragging, .scrolling, .ignoring:
            break
        }
        return []
    }

    public mutating func touchesMoved(_ touches: [TrackpadTouch]) -> [TrackpadOutput] {
        var output: [TrackpadOutput] = []
        for touch in touches where fingers[touch.id] != nil {
            let point = Point(x: touch.x, y: touch.y)
            fingers[touch.id] = point
            switch phase {
            case .pending(let id, let origin, _, let second):
                guard touch.id == id, hypot(point.x - origin.x, point.y - origin.y) > Self.travelThreshold else { continue }
                if second { output.append(.buttonDown(timeMicros: touch.timeMicros)) }
                output.append(.move(dx: point.x - origin.x, dy: point.y - origin.y, timeMicros: touch.timeMicros))
                lastTap = nil
                phase = second ? .dragging(id: id, last: point) : .moving(id: id, last: point)
            case .moving(let id, let last):
                guard touch.id == id else { continue }
                output.append(.move(dx: point.x - last.x, dy: point.y - last.y, timeMicros: touch.timeMicros))
                phase = .moving(id: id, last: point)
            case .dragging(let id, let last):
                guard touch.id == id else { continue }
                output.append(.move(dx: point.x - last.x, dy: point.y - last.y, timeMicros: touch.timeMicros))
                phase = .dragging(id: id, last: point)
            case .twoPending(let a, let b, let origin, let landedA, let landedB, let startedAt, let tap):
                guard touch.id == a || touch.id == b, let first = fingers[a], let second = fingers[b] else { continue }
                let centre = Self.centre(first, second)
                guard hypot(centre.x - origin.x, centre.y - origin.y) > Self.travelThreshold else {
                    let travel = max(hypot(first.x - landedA.x, first.y - landedA.y), hypot(second.x - landedB.x, second.y - landedB.y))
                    if tap, travel > Self.twoFingerTapMaxTravel {
                        phase = .twoPending(
                            a: a, b: b, origin: origin, landedA: landedA, landedB: landedB, startedAt: startedAt, tap: false)
                    }
                    continue
                }
                lastTap = nil
                output.append(.scrollBegan(timeMicros: touch.timeMicros))
                output.append(.scroll(dx: centre.x - origin.x, dy: centre.y - origin.y, timeMicros: touch.timeMicros))
                phase = .scrolling(a: a, b: b, last: centre)
            case .scrolling(let a, let b, let last):
                guard touch.id == a || touch.id == b, let first = fingers[a], let second = fingers[b] else { continue }
                let centre = Self.centre(first, second)
                output.append(.scroll(dx: centre.x - last.x, dy: centre.y - last.y, timeMicros: touch.timeMicros))
                phase = .scrolling(a: a, b: b, last: centre)
            case .twoLifting(let id, let landed, _):
                guard touch.id == id, hypot(point.x - landed.x, point.y - landed.y) > Self.twoFingerTapMaxTravel else { continue }
                phase = .ignoring
            case .idle, .ignoring:
                break
            }
        }
        return output
    }

    public mutating func touchesEnded(_ touches: [TrackpadTouch]) -> [TrackpadOutput] {
        var output: [TrackpadOutput] = []
        for touch in touches where fingers[touch.id] != nil {
            fingers[touch.id] = nil
            switch phase {
            case .pending(let id, let origin, let startedAt, _):
                guard touch.id == id else { continue }
                if touch.timeMicros &- startedAt <= Self.tapMaxMicros {
                    output.append(.click(count: tapCount(at: origin, lift: touch.timeMicros), timeMicros: touch.timeMicros))
                } else {
                    lastTap = nil
                }
                phase = fingers.isEmpty ? .idle : .ignoring
            case .moving(let id, _):
                guard touch.id == id else { continue }
                phase = fingers.isEmpty ? .idle : .ignoring
            case .dragging(let id, _):
                guard touch.id == id else { continue }
                output.append(.buttonUp(timeMicros: touch.timeMicros))
                phase = fingers.isEmpty ? .idle : .ignoring
            case .twoPending(let a, let b, _, let landedA, let landedB, let startedAt, let tap):
                guard touch.id == a || touch.id == b else { continue }
                let rest = touch.id == a ? b : a
                if tap, fingers.count == 1, fingers[rest] != nil, touch.timeMicros &- startedAt <= Self.twoFingerTapMaxMicros {
                    phase = .twoLifting(id: rest, landed: rest == a ? landedA : landedB, startedAt: startedAt)
                } else {
                    phase = fingers.isEmpty ? .idle : .ignoring
                }
            case .twoLifting(let id, _, let startedAt):
                guard touch.id == id else { continue }
                if touch.timeMicros &- startedAt <= Self.twoFingerTapMaxMicros { output.append(.rightClick(timeMicros: touch.timeMicros)) }
                phase = fingers.isEmpty ? .idle : .ignoring
            case .scrolling(let a, let b, _):
                guard touch.id == a || touch.id == b else { continue }
                output.append(.scrollEnded(timeMicros: touch.timeMicros))
                phase = fingers.isEmpty ? .idle : .ignoring
            case .ignoring, .idle:
                break
            }
        }
        if fingers.isEmpty { phase = .idle }
        return output
    }

    /// The system took the touches away. A drag is released and a scroll ended; a pending tap is dropped.
    public mutating func touchesCancelled(atMicros time: UInt64) -> [TrackpadOutput] {
        var output: [TrackpadOutput] = []
        switch phase {
        case .dragging: output.append(.buttonUp(timeMicros: time))
        case .scrolling: output.append(.scrollEnded(timeMicros: time))
        case .idle, .pending, .moving, .twoPending, .twoLifting, .ignoring: break
        }
        phase = .idle
        lastTap = nil
        fingers.removeAll()
        return output
    }

    // MARK: Time

    /// Called regularly while the pad is shown. Only a long press needs it: 400 ms, or 200 ms for a second press.
    public mutating func tick(nowMicros now: UInt64) -> [TrackpadOutput] {
        guard case .pending(let id, _, let startedAt, let second) = phase,
              now &- startedAt >= (second ? Self.tapMaxMicros : Self.longPressMicros),
              let position = fingers[id] else { return [] }
        lastTap = nil
        phase = .dragging(id: id, last: position)
        return [.buttonDown(timeMicros: now)]
    }

    /// The count for a tap that just lifted at `point`: 2 for the second tap of a double click, which then starts over.
    private mutating func tapCount(at point: Point, lift: UInt64) -> Int {
        if let previous = lastTap, lift &- previous.time <= Self.doubleTapMaxMicros,
           hypot(point.x - previous.point.x, point.y - previous.point.y) <= Self.doubleTapMaxDistance {
            lastTap = nil
            return 2
        }
        lastTap = (point, lift)
        return 1
    }

    private static func centre(_ a: Point, _ b: Point) -> Point {
        Point(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}
