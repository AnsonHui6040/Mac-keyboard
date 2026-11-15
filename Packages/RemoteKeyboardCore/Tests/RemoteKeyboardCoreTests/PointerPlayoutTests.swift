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

    // MARK: The lag bound follows the measured arrival period

    private struct Run {
        var outputs: [UInt64] = []
        var squeezesAt: [(time: UInt64, count: Int)] = []
        var totalOut = 0.0
        var totalIn = 0.0
        var boundAfterEnqueue: [UInt64] = []
    }

    /// One simulated stroke: bursts of moves arrive every `period` microseconds (the moves of a burst `intra` apart), the
    /// frame tick runs every 8 ms.
    private func simulate(bursts: [Int], period: UInt64, intra: UInt64, span: UInt64, count: Int) -> Run {
        var playout = PointerPlayout()
        var run = Run()
        var enqueues: [(time: UInt64, dx: Double)] = []
        for b in 0..<count {
            for i in 0..<bursts[b % bursts.count] {
                enqueues.append((UInt64(b) * period + UInt64(i) * intra, 1.0 + Double(i)))
            }
        }
        let end = enqueues.last!.time + 100 * ms
        var next = 0
        var t: UInt64 = 0
        while t <= end {
            while next < enqueues.count && enqueues[next].time <= t {
                let item = enqueues[next]
                playout.enqueue(dx: item.dx, dy: 0, dragging: false, spanMicros: span, nowMicros: item.time)
                run.totalIn += item.dx
                next += 1
                run.squeezesAt.append((item.time, playout.squeezeCount))
                run.boundAfterEnqueue.append(playout.lagBoundMicros)
            }
            if let share = playout.take(nowMicros: t) {
                run.outputs.append(t)
                run.totalOut += share.dx
            }
            t += 8 * ms
        }
        for share in playout.flush() { run.totalOut += share.dx }
        return run
    }

    /// (largest gap between consecutive outputs, squeezes) over the part of the stroke after the first three bursts and
    /// before the last burst.
    private func steadyState(_ run: Run, period: UInt64, count: Int) -> (maxGap: UInt64, squeezes: Int) {
        let from = 3 * period
        let to = UInt64(count - 1) * period
        let times = run.outputs.filter { $0 >= from && $0 <= to }
        var maxGap: UInt64 = 0
        for pair in zip(times, times.dropFirst()) { maxGap = max(maxGap, pair.1 - pair.0) }
        let before = run.squeezesAt.last { $0.time < from }?.count ?? 0
        let after = run.squeezesAt.last { $0.time <= to }?.count ?? 0
        return (maxGap, after - before)
    }

    func testALinuxStyleBurstStreamPlaysOutWithoutStopAndGo() {
        // 3,3,2 moves of 16.6 ms every 45 ms, the moves of a burst 1 ms apart (the measured Linux link).
        let run = simulate(bursts: [3, 3, 2], period: 45 * ms, intra: ms, span: 16_600, count: 24)
        let (maxGap, squeezes) = steadyState(run, period: 45 * ms, count: 24)
        XCTAssertLessThanOrEqual(maxGap, 12 * ms, "output stands still for \(maxGap) us between bursts (\(squeezes) squeezes)")
        // A burst can land on a few ms of unplayed queue and then squeeze by a few percent, about once per 3,3,2 cycle;
        // the old rule squeezed 34 times here.
        XCTAssertLessThanOrEqual(squeezes, 8, "\(squeezes) squeezes after warm-up")
    }

    func testABurstStreamKeepsEveryBitOfDisplacement() {
        let run = simulate(bursts: [3, 3, 2], period: 45 * ms, intra: ms, span: 16_600, count: 24)
        XCTAssertEqual(run.totalOut, run.totalIn, accuracy: 1e-6)
    }

    func testAWindowsStyleStreamKeepsTodaysLagBound() {
        let run = simulate(bursts: [1], period: 15 * ms, intra: 0, span: 15 * ms, count: 80)
        XCTAssertTrue(run.boundAfterEnqueue.allSatisfy { $0 == PointerPlayout.maxLagMicros }, "\(run.boundAfterEnqueue)")
        let (maxGap, squeezes) = steadyState(run, period: 15 * ms, count: 80)
        XCTAssertEqual(squeezes, 0)
        XCTAssertLessThanOrEqual(maxGap, 8 * ms)
    }

    func testOneLongGapAmongRegularOnesDoesNotMoveTheBound() {
        var playout = PointerPlayout()
        var t: UInt64 = 0
        for gap: UInt64 in [45, 45, 45, 45, 90, 45, 45] {
            t += gap * ms
            playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 16_600, nowMicros: t)
        }
        XCTAssertEqual(playout.lagBoundMicros, 45 * ms + PointerPlayout.lagMarginMicros)
    }

    func testAPauseIsNotCountedAsAnArrivalPeriod() {
        var playout = PointerPlayout()
        var t: UInt64 = 0
        for _ in 0..<4 {
            t += 45 * ms
            playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 16_600, nowMicros: t)
        }
        t += 200 * ms
        playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 16_600, nowMicros: t)
        XCTAssertEqual(playout.lagBoundMicros, 45 * ms + PointerPlayout.lagMarginMicros, "a 200 ms gap is a pause")
    }

    func testALongPauseForgetsTheHistory() {
        var playout = PointerPlayout()
        var t: UInt64 = 0
        for _ in 0..<5 {
            t += 45 * ms
            playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 16_600, nowMicros: t)
        }
        XCTAssertEqual(playout.lagBoundMicros, 50 * ms)
        t += 400 * ms
        playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 10 * ms, nowMicros: t)
        XCTAssertEqual(playout.lagBoundMicros, PointerPlayout.maxLagMicros, "the first burst after a long pause uses the plain rule")
    }

    func testTheAdaptiveBoundIsCapped() {
        var playout = PointerPlayout()
        for i in 0..<10 as Range<UInt64> {
            playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 16_600, nowMicros: i * 100 * ms)
        }
        XCTAssertEqual(playout.lagBoundMicros, PointerPlayout.maxAdaptiveLagMicros)
        XCTAssertEqual(PointerPlayout.maxAdaptiveLagMicros, 60 * ms)
    }

    func testDiscardForgetsTheArrivalHistory() {
        var playout = PointerPlayout()
        XCTAssertEqual(playout.lagBoundMicros, PointerPlayout.maxLagMicros, "the floor before the first enqueue")
        for i in 1...6 as ClosedRange<UInt64> {
            playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 16_600, nowMicros: i * 45 * ms)
        }
        XCTAssertEqual(playout.lagBoundMicros, 50 * ms)
        playout.discard()
        playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 16_600, nowMicros: 400 * ms)
        playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 16_600, nowMicros: 445 * ms)
        XCTAssertEqual(playout.lagBoundMicros, 50 * ms, "one gap of 45 ms after the discard is the whole history")
        playout.discard()
        playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 16_600, nowMicros: 500 * ms)
        XCTAssertEqual(playout.lagBoundMicros, max(PointerPlayout.maxLagMicros, 16_600 + PointerPlayout.lagMarginMicros))
    }

    // MARK: The adaptive jitter buffer

    private struct MacRun {
        var outputs: [(time: UInt64, stroke: Int)] = []
        var underrunsAtWarmUp = 0
        var underruns = 0
        var maxAllowance: UInt64 = 0
        var totalIn = 0.0
        var totalOut = 0.0
    }

    /// The Mac link: the phone sends a 16.6 ms MOVE every 16.6 ms, the Mac gets it at the next 15 ms connection event, and
    /// every 16th packet is held back 60 ms with the ones after it bunched behind it. `strokes` strokes of `strokeMs` each,
    /// 300 ms apart; the frame tick runs every 8 ms.
    private func simulateMacStream(strokes: Int, strokeMs: UInt64) -> MacRun {
        var playout = PointerPlayout()
        var run = MacRun()
        var arrivals: [(time: UInt64, dx: Double, stroke: Int)] = []
        var previous: UInt64 = 0
        var packet = 0
        for stroke in 0..<strokes {
            let origin = UInt64(stroke) * (strokeMs + 300) * ms
            var sent = origin
            while sent < origin + strokeMs * ms {
                var arrival = (sent + 14_999) / 15_000 * 15_000
                if packet % 16 == 15 { arrival += 60 * ms }
                arrival = max(arrival, previous)
                previous = arrival
                arrivals.append((arrival, 1.0 + Double(packet % 3), stroke))
                sent += 16_600
                packet += 1
            }
        }
        var next = 0
        var strokeAt: [Int] = []
        var t: UInt64 = 0
        let end = arrivals.last!.time + 400 * ms
        var warmUpTaken = false
        while t <= end {
            while next < arrivals.count && arrivals[next].time <= t {
                let item = arrivals[next]
                playout.enqueue(dx: item.dx, dy: 0, dragging: false, spanMicros: 16_600, nowMicros: item.time)
                run.totalIn += item.dx
                run.maxAllowance = max(run.maxAllowance, playout.jitterAllowanceMicros)
                strokeAt.append(item.stroke)
                next += 1
            }
            if !warmUpTaken && t >= 1_000 * ms {
                run.underrunsAtWarmUp = playout.underrunCount
                warmUpTaken = true
            }
            if let share = playout.take(nowMicros: t) {
                run.outputs.append((t, strokeAt.last ?? 0))
                run.totalOut += share.dx
            }
            t += 8 * ms
        }
        for share in playout.flush() { run.totalOut += share.dx }
        run.underruns = playout.underrunCount
        return run
    }

    func testAMacStyleStreamWithRadioPausesStopsStandingStillAfterWarmUp() {
        let run = simulateMacStream(strokes: 4, strokeMs: 2_200)
        var longest: UInt64 = 0
        for pair in zip(run.outputs, run.outputs.dropFirst())
        where pair.0.time >= 1_000 * ms && pair.0.stroke == pair.1.stroke {
            longest = max(longest, pair.1.time - pair.0.time)
        }
        XCTAssertLessThanOrEqual(longest, 25 * ms, "the cursor stood still for \(longest) us")
        XCTAssertLessThanOrEqual(run.underruns - run.underrunsAtWarmUp, 3, "underruns after warm-up")
    }

    func testAMacStyleStreamKeepsEveryBitOfDisplacement() {
        let run = simulateMacStream(strokes: 4, strokeMs: 2_200)
        XCTAssertEqual(run.totalOut, run.totalIn, accuracy: 1e-6)
    }

    func testACleanFifteenMillisecondStreamBehavesExactlyAsToday() throws {
        var playout = PointerPlayout()
        var totalIn = 0.0, totalOut = 0.0
        for i in 0..<660 as Range<UInt64> {  // 10 s
            let now = i * 15 * ms
            playout.enqueue(dx: 3, dy: 0, dragging: false, spanMicros: 15 * ms, nowMicros: now)
            totalIn += 3
            XCTAssertEqual(playout.jitterAllowanceMicros, 0)
            XCTAssertEqual(playout.lagBoundMicros, PointerPlayout.maxLagMicros)
            if i == 0 {
                XCTAssertNil(playout.take(nowMicros: now), "the first segment starts at now")
                let half = try XCTUnwrap(playout.take(nowMicros: now + 7_500))
                XCTAssertEqual(half.dx, 1.5, accuracy: 1e-9, "no start delay and no stretch")
                totalOut += half.dx
            }
            if let share = playout.take(nowMicros: now + 14_999) { totalOut += share.dx }
        }
        XCTAssertEqual(playout.underrunCount, 0)
        XCTAssertEqual(playout.squeezeCount, 0)
        for share in playout.flush() { totalOut += share.dx }
        XCTAssertEqual(totalOut, totalIn, accuracy: 1e-6)
    }

    /// A regular 15 ms stream of 15 ms packets whose last packet came at 60 ms.
    private func regularPlayout() -> PointerPlayout {
        var playout = PointerPlayout()
        for i in 0..<5 as Range<UInt64> {
            playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 15 * ms, nowMicros: i * 15 * ms)
        }
        return playout
    }

    private func enqueueAfter(_ gap: UInt64, _ playout: inout PointerPlayout, previous: UInt64 = 60_000) {
        playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 15 * ms, nowMicros: previous + gap)
    }

    func testAnArrivalGapBeyondThePeriodPlusTheThresholdRaisesTheAllowanceByTheExcessPlusTheMargin() {
        var playout = regularPlayout()
        enqueueAfter(50 * ms, &playout)
        XCTAssertEqual(playout.pauseCount, 1)
        XCTAssertEqual(playout.underrunCount, 1)
        XCTAssertEqual(playout.jitterAllowanceMicros, 40 * ms, "gap 50 - period 15 + margin 5")
    }

    func testAQuantisedThirtyMillisecondGapOnAFifteenMillisecondLinkIsNoPause() {
        var playout = regularPlayout()
        enqueueAfter(30 * ms, &playout)
        XCTAssertEqual(playout.underrunCount, 1, "the queue did run dry")
        XCTAssertEqual(playout.pauseCount, 0)
        XCTAssertEqual(playout.jitterAllowanceMicros, 0, "a standstill alone raises nothing")
    }

    func testOneMissedSlotIsNoPauseAndNeitherIsAGapWithoutAMeasuredPeriod() {
        var playout = PointerPlayout()
        playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 15 * ms, nowMicros: 0)
        playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 15 * ms, nowMicros: 90 * ms)
        XCTAssertEqual(playout.pauseCount, 0, "no period is known yet")
        var slow = PointerPlayout()
        var t: UInt64 = 0
        for gap: UInt64 in [45, 45, 45, 45, 90] {
            t += gap * ms
            slow.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 16_600, nowMicros: t)
        }
        XCTAssertEqual(slow.pauseCount, 0, "90 ms on a 45 ms period is one missed slot")
    }

    func testAClockThatGoesBackwardsNeitherTrapsNorCountsAPause() {
        var playout = PointerPlayout()
        playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 15 * ms, nowMicros: 100_000)
        playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 15 * ms, nowMicros: 90_000)
        XCTAssertEqual(playout.pauseCount, 0)
        var warm = regularPlayout()
        warm.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 15 * ms, nowMicros: 30_000)
        XCTAssertEqual(warm.pauseCount, 0)
    }

    func testASustainedChangeOfTheArrivalIntervalIsLearnedAndTheAllowanceDecays() {
        // A renegotiated connection: 15 ms intervals, then a steady 45 ms.
        var playout = regularPlayout()
        var now: UInt64 = 60_000
        var pausesAfterSwitch = 0
        for _ in 0..<(20_000 / 45) {
            now += 45 * ms
            let before = playout.pauseCount
            playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 16_600, nowMicros: now)
            pausesAfterSwitch += playout.pauseCount - before
        }
        XCTAssertLessThanOrEqual(pausesAfterSwitch, 3, "after three pause-sized gaps in a row the new period is the norm")
        XCTAssertEqual(playout.jitterAllowanceMicros, 0, "no new pauses: the allowance decayed away")
        XCTAssertEqual(playout.lagBoundMicros, 45 * ms + PointerPlayout.lagMarginMicros, "the period follows the new interval")
    }

    func testPausesDoNotDriftTheMeasuredArrivalPeriod() {
        // A 15 ms stream where every second gap is a 75 ms pause: if the pauses were recorded as periods the median would
        // become 75 ms and the later pauses would no longer be seen.
        var playout = regularPlayout()
        var now: UInt64 = 60_000
        for _ in 0..<12 {
            now += 75 * ms
            playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 15 * ms, nowMicros: now)
            now += 15 * ms
            playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 15 * ms, nowMicros: now)
        }
        XCTAssertEqual(playout.pauseCount, 12)
    }

    func testAMoveRightAfterAFlushIsNotAFalseUnderrunAndStillRefills() throws {
        var playout = regularPlayout()
        enqueueAfter(45 * ms, &playout)  // allowance 35 ms
        _ = playout.flush()
        playout.enqueue(dx: 8, dy: 0, dragging: false, spanMicros: 8 * ms, nowMicros: 500_000)  // a new stroke, starts after the allowance
        _ = playout.flush()  // the click: lastEnd would stay about 45 ms ahead
        let underruns = playout.underrunCount
        playout.enqueue(dx: 8, dy: 0, dragging: false, spanMicros: 8 * ms, nowMicros: 505_000)
        XCTAssertEqual(playout.underrunCount, underruns, "the emptied queue is not a run-out")
        let part = try XCTUnwrap(playout.take(nowMicros: 513_000))
        XCTAssertLessThan(part.dx, 8 - 1e-6, "the empty buffer is refilled: the segment plays stretched, and without a start delay")
    }

    func testTheAllowanceDecaysAfterACleanStretch() throws {
        var playout = regularPlayout()
        enqueueAfter(45 * ms, &playout)
        let raised = playout.jitterAllowanceMicros
        XCTAssertEqual(raised, 35 * ms)
        var now = 105 * ms
        var halfLifeValue: UInt64?
        while now < 15_105 * ms {
            now += 15 * ms
            playout.enqueue(dx: 1, dy: 0, dragging: false, spanMicros: 15 * ms, nowMicros: now)
            if now == 5_100 * ms { halfLifeValue = playout.jitterAllowanceMicros }
        }
        XCTAssertEqual(Double(try XCTUnwrap(halfLifeValue)), Double(raised) / 2, accuracy: Double(raised) * 0.02, "halves in 5 s")
        XCTAssertEqual(playout.jitterAllowanceMicros, 0, "below the 5 ms floor after 15 s")
    }

    func testTheAllowanceIsCapped() {
        var playout = regularPlayout()
        enqueueAfter(95 * ms, &playout)
        XCTAssertEqual(playout.jitterAllowanceMicros, PointerPlayout.maxJitterMicros, "95 - 15 + 5 = 85 ms is capped at 80 ms")
    }

    func testAGapLongerThanAStrokeGapIsANewStrokeNotAPause() {
        var playout = regularPlayout()
        enqueueAfter(200 * ms, &playout)
        XCTAssertEqual(playout.pauseCount, 0)
        XCTAssertEqual(playout.jitterAllowanceMicros, 0)
    }

    func testANewStrokeStartsAfterTheAllowance() throws {
        var playout = regularPlayout()
        enqueueAfter(45 * ms, &playout)
        _ = playout.flush()
        playout.enqueue(dx: 8, dy: 0, dragging: false, spanMicros: 8 * ms, nowMicros: 500 * ms)
        let allowance = playout.jitterAllowanceMicros
        XCTAssertGreaterThan(allowance, 0)
        XCTAssertNil(playout.take(nowMicros: 500 * ms + allowance - ms), "nothing plays before the allowance has passed")
        XCTAssertNotNil(playout.take(nowMicros: 500 * ms + allowance + 2 * ms))
    }

    func testDiscardForgetsTheAllowance() {
        var playout = regularPlayout()
        enqueueAfter(45 * ms, &playout)
        XCTAssertGreaterThan(playout.jitterAllowanceMicros, 0)
        playout.discard()
        XCTAssertEqual(playout.jitterAllowanceMicros, 0)
        playout.enqueue(dx: 8, dy: 0, dragging: false, spanMicros: 8 * ms, nowMicros: 200 * ms)
        XCTAssertNil(playout.take(nowMicros: 200 * ms))
        XCTAssertNotNil(playout.take(nowMicros: 204 * ms), "the stroke after a discard starts at once")
    }

    func testTheLimitsOfTheJitterBufferAreTheDocumentedOnes() {
        XCTAssertEqual(PointerPlayout.maxJitterMicros, 80_000)
        XCTAssertEqual(PointerPlayout.pauseThresholdMicros, 20_000)
        XCTAssertEqual(PointerPlayout.jitterDecayHalfLifeMicros, 5_000_000)
        XCTAssertEqual(PointerPlayout.jitterFloorMicros, 5_000)
        XCTAssertEqual(PointerPlayout.refillStretch, 1.25)
        XCTAssertEqual(PointerPlayout.strokeGapMicros, 100_000)
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
