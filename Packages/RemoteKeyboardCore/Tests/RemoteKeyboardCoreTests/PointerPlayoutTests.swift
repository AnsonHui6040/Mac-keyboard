import XCTest
@testable import RemoteKeyboardCore

final class PointerPlayoutTests: XCTestCase {
    private let ms: UInt64 = 1_000

    func testASingleSegmentIsHandedOutLinearly() throws {
        var playout = PointerPlayout()
        playout.enqueue(dx: 10, dy: -20, dragging: false, spanMicros: 10 * ms, nowMicros: 100 * ms)
        XCTAssertFalse(playout.isIdle)
        XCTAssertNil(playout.take(nowMicros: 100 * ms), "nothing has elapsed yet")
        let half = try XCTUnwrap(playout.take(nowMicros: 105 * ms))
        XCTAssertEqual(half.dx, 5, accuracy: 1e-9)
        XCTAssertEqual(half.dy, -10, accuracy: 1e-9)
        XCTAssertFalse(half.dragging)
        let rest = try XCTUnwrap(playout.take(nowMicros: 200 * ms))
        XCTAssertEqual(rest.dx, 5, accuracy: 1e-9)
        XCTAssertEqual(rest.dy, -10, accuracy: 1e-9)
        XCTAssertTrue(playout.isIdle)
        XCTAssertNil(playout.take(nowMicros: 300 * ms))
    }

    func testTwoPacketsArrivingTogetherPlayBackToBackNotOnTopOfEachOther() throws {
        var playout = PointerPlayout()
        playout.enqueue(dx: 8, dy: 0, dragging: false, spanMicros: 8 * ms, nowMicros: 0)
        playout.enqueue(dx: 8, dy: 0, dragging: false, spanMicros: 8 * ms, nowMicros: 0)
        // One unit per millisecond over 16 ms: every 4 ms step yields the same 4.
        var last: UInt64 = 0
        for step in 1...4 {
            last = UInt64(step) * 4 * ms
            let moved = try XCTUnwrap(playout.take(nowMicros: last))
            XCTAssertEqual(moved.dx, 4, accuracy: 1e-9, "step \(step)")
        }
        XCTAssertTrue(playout.isIdle)
    }

    func testASegmentStartsWhereTheLastEndedWhenItIsStillRunning() throws {
        var playout = PointerPlayout()
        playout.enqueue(dx: 10, dy: 0, dragging: false, spanMicros: 10 * ms, nowMicros: 0)
        playout.enqueue(dx: 10, dy: 0, dragging: false, spanMicros: 10 * ms, nowMicros: 5 * ms)
        let atTen = try XCTUnwrap(playout.take(nowMicros: 10 * ms))
        XCTAssertEqual(atTen.dx, 10, accuracy: 1e-9, "the second segment has not started before 10 ms")
        let atFifteen = try XCTUnwrap(playout.take(nowMicros: 15 * ms))
        XCTAssertEqual(atFifteen.dx, 5, accuracy: 1e-9)
    }

    func testAMissingOrTinySpanUsesTheDefaultAndALongOneIsCapped() throws {
        var zero = PointerPlayout()
        zero.enqueue(dx: 8, dy: 0, dragging: false, spanMicros: 0, nowMicros: 0)
        XCTAssertEqual(try XCTUnwrap(zero.take(nowMicros: 4 * ms)).dx, 4, accuracy: 1e-9, "0 means the 8 ms default")

        var tiny = PointerPlayout()
        tiny.enqueue(dx: 8, dy: 0, dragging: false, spanMicros: 1, nowMicros: 0)
        XCTAssertEqual(try XCTUnwrap(tiny.take(nowMicros: 2 * ms)).dx, 4, accuracy: 1e-9, "raised to 4 ms")

        var long = PointerPlayout()
        long.enqueue(dx: 25, dy: 0, dragging: false, spanMicros: 900 * ms, nowMicros: 0)
        // Capped to 50 ms; a lone segment is within its own span plus 5 ms, so it is not squeezed: half by 25 ms.
        XCTAssertEqual(try XCTUnwrap(long.take(nowMicros: 25 * ms)).dx, 12.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(long.take(nowMicros: 50 * ms)).dx, 12.5, accuracy: 1e-9)
        XCTAssertTrue(long.isIdle)
    }

    func testTheLimitsAreTheLowLatencyOnes() {
        XCTAssertEqual(PointerPlayout.maxLagMicros, 20_000)
        XCTAssertEqual(PointerPlayout.maxSpanMicros, 50_000)
        XCTAssertEqual(PointerPlayout.lagMarginMicros, 5_000)
    }

    func testLagIsCappedByCompressingWhatIsLeft() throws {
        var playout = PointerPlayout()
        let cap = PointerPlayout.maxLagMicros
        // Short packets (8 ms): the bound is the 20 ms floor. 80 ms of queue at now = 0 is squeezed so that it ends at the cap.
        for _ in 0..<10 { playout.enqueue(dx: 10, dy: 0, dragging: false, spanMicros: 8 * ms, nowMicros: 0) }
        XCTAssertNil(playout.take(nowMicros: 0))
        let all = try XCTUnwrap(playout.take(nowMicros: cap))
        XCTAssertEqual(all.dx, 100, accuracy: 1e-9)
        XCTAssertTrue(playout.isIdle)
    }

    func testTheLagBoundIsTheSpanPlusFiveMillisecondsForLongPacketsAndTwentyForShortOnes() throws {
        // Long packets (30 ms): the bound is 35 ms. 60 ms of queue is squeezed to end at 35 ms, not at 20.
        var long = PointerPlayout()
        long.enqueue(dx: 30, dy: 0, dragging: false, spanMicros: 30 * ms, nowMicros: 0)
        long.enqueue(dx: 30, dy: 0, dragging: false, spanMicros: 30 * ms, nowMicros: 0)
        let at20 = try XCTUnwrap(long.take(nowMicros: 20 * ms))
        XCTAssertLessThan(at20.dx, 60 - 1e-6, "not all out by 20 ms")
        XCTAssertEqual(at20.dx, 60 * 20.0 / 35, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(long.take(nowMicros: 35 * ms)).dx, 60 - at20.dx, accuracy: 1e-9)
        XCTAssertTrue(long.isIdle)

        // A single 50 ms packet is never squeezed (its own span plus 5 ms is more than it needs).
        var single = PointerPlayout()
        single.enqueue(dx: 50, dy: 0, dragging: false, spanMicros: 50 * ms, nowMicros: 0)
        XCTAssertEqual(try XCTUnwrap(single.take(nowMicros: 10 * ms)).dx, 10, accuracy: 1e-9)

        // Short packets (8 ms): the bound is 20 ms.
        var short = PointerPlayout()
        for _ in 0..<5 { short.enqueue(dx: 8, dy: 0, dragging: false, spanMicros: 8 * ms, nowMicros: 0) }
        XCTAssertEqual(try XCTUnwrap(short.take(nowMicros: 20 * ms)).dx, 40, accuracy: 1e-9)
        XCTAssertTrue(short.isIdle)
    }

    func testASteadyStreamOfLongPacketsPlaysSmoothlyFrameByFrame() {
        var rng = SplitMix64(seed: 0x5EED)
        var playout = PointerPlayout()
        let frame: UInt64 = 8_333
        let ideal = 30.0 * Double(frame) / 30_000
        var nextPacket = 0
        var outputs: [Double] = []
        var frameTime: UInt64 = 0
        while frameTime < 1_200 * ms {
            frameTime += frame
            // Packets arrive every 30 ms with up to 3 ms of jitter either way.
            while nextPacket < 40 {
                let arrival = UInt64(Int64(nextPacket) * 30 * Int64(ms) + 30 * Int64(ms) + Int64(rng.next() % 7_001) - 3_500)
                guard arrival <= frameTime else { break }
                playout.enqueue(dx: 30, dy: 0, dragging: false, spanMicros: 30 * ms, nowMicros: arrival)
                nextPacket += 1
            }
            outputs.append(playout.take(nowMicros: frameTime)?.dx ?? 0)
        }
        // Skip the start-up and the end of the stream.
        let steady = outputs[8..<(outputs.count - 40 / 4)].prefix(100)
        XCTAssertGreaterThan(steady.count, 80)
        for (index, value) in steady.enumerated() {
            XCTAssertGreaterThan(value, 0, "frame \(index) is empty mid-stream")
            XCTAssertLessThanOrEqual(value, ideal * 1.3, "frame \(index) runs too fast")
        }
    }

    func testSqueezeCountOnlyCountsSqueezes() {
        var playout = PointerPlayout()
        playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 8_000, nowMicros: 0)
        XCTAssertEqual(playout.squeezeCount, 0)
        for _ in 0..<5 { playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 8_000, nowMicros: 0) }
        XCTAssertGreaterThan(playout.squeezeCount, 0)
    }

    func testAShortQueueIsNotCompressed() throws {
        var playout = PointerPlayout()
        playout.enqueue(dx: 10, dy: 0, dragging: false, spanMicros: 10 * ms, nowMicros: 0)
        playout.enqueue(dx: 10, dy: 0, dragging: false, spanMicros: 10 * ms, nowMicros: 0)
        XCTAssertEqual(try XCTUnwrap(playout.take(nowMicros: 10 * ms)).dx, 10, accuracy: 1e-9)
    }

    func testDraggingChangeIsNeverMergedIntoOneOutput() throws {
        var playout = PointerPlayout()
        playout.enqueue(dx: 4, dy: 0, dragging: false, spanMicros: 4 * ms, nowMicros: 0)
        playout.enqueue(dx: 6, dy: 0, dragging: true, spanMicros: 4 * ms, nowMicros: 0)
        let first = try XCTUnwrap(playout.take(nowMicros: 100 * ms))
        XCTAssertEqual(first.dx, 4, accuracy: 1e-9)
        XCTAssertFalse(first.dragging)
        let second = try XCTUnwrap(playout.take(nowMicros: 100 * ms))
        XCTAssertEqual(second.dx, 6, accuracy: 1e-9)
        XCTAssertTrue(second.dragging)
        XCTAssertNil(playout.take(nowMicros: 100 * ms))
        XCTAssertTrue(playout.isIdle)
    }

    func testSameDraggingStateIsMergedAcrossSegments() throws {
        var playout = PointerPlayout()
        playout.enqueue(dx: 4, dy: 1, dragging: true, spanMicros: 4 * ms, nowMicros: 0)
        playout.enqueue(dx: 6, dy: 2, dragging: true, spanMicros: 4 * ms, nowMicros: 0)
        let all = try XCTUnwrap(playout.take(nowMicros: 100 * ms))
        XCTAssertEqual(all.dx, 10, accuracy: 1e-9)
        XCTAssertEqual(all.dy, 3, accuracy: 1e-9)
    }

    func testFlushHandsOutEverythingAtOnceInRunsOfTheSameDraggingState() {
        var playout = PointerPlayout()
        playout.enqueue(dx: 4, dy: 0, dragging: false, spanMicros: 8 * ms, nowMicros: 0)
        playout.enqueue(dx: 2, dy: 0, dragging: false, spanMicros: 8 * ms, nowMicros: 0)
        playout.enqueue(dx: 7, dy: 0, dragging: true, spanMicros: 8 * ms, nowMicros: 0)
        _ = playout.take(nowMicros: 4 * ms)
        let flushed = playout.flush()
        XCTAssertEqual(flushed.count, 2)
        XCTAssertFalse(flushed[0].dragging)
        XCTAssertTrue(flushed[1].dragging)
        XCTAssertEqual(flushed[1].dx, 7, accuracy: 1e-9)
        XCTAssertTrue(playout.isIdle)
        XCTAssertEqual(playout.flush().count, 0)
    }

    func testDiscardDropsEverything() {
        var playout = PointerPlayout()
        playout.enqueue(dx: 4, dy: 0, dragging: false, spanMicros: 8 * ms, nowMicros: 0)
        playout.discard()
        XCTAssertTrue(playout.isIdle)
        XCTAssertNil(playout.take(nowMicros: 100 * ms))
        XCTAssertEqual(playout.flush().count, 0)
    }

    func testTotalDisplacementIsConservedForRandomSequences() {
        var rng = SplitMix64(seed: 0xC0FFEE)
        for _ in 0..<200 {
            var playout = PointerPlayout()
            var now: UInt64 = 1_000_000
            var sumIn = (x: 0.0, y: 0.0), sumOut = (x: 0.0, y: 0.0)
            for _ in 0..<Int(rng.next() % 60 + 1) {
                now += rng.next() % (30 * ms)
                let dx = Double(Int64(rng.next() % 2001) - 1000) / 16
                let dy = Double(Int64(rng.next() % 2001) - 1000) / 16
                playout.enqueue(
                    dx: dx, dy: dy, dragging: rng.next() % 5 == 0, spanMicros: rng.next() % (60 * ms), nowMicros: now)
                sumIn.x += dx
                sumIn.y += dy
                now += rng.next() % (20 * ms)
                switch rng.next() % 3 {
                case 0:
                    while let m = playout.take(nowMicros: now) { sumOut.x += m.dx; sumOut.y += m.dy }
                case 1:
                    for m in playout.flush() { sumOut.x += m.dx; sumOut.y += m.dy }
                default:
                    break
                }
            }
            while let m = playout.take(nowMicros: now + 10_000_000) { sumOut.x += m.dx; sumOut.y += m.dy }
            for m in playout.flush() { sumOut.x += m.dx; sumOut.y += m.dy }
            XCTAssertTrue(playout.isIdle)
            XCTAssertEqual(sumOut.x, sumIn.x, accuracy: 1e-9)
            XCTAssertEqual(sumOut.y, sumIn.y, accuracy: 1e-9)
        }
    }
}

/// A fixed-seed generator, so a failure repeats.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
