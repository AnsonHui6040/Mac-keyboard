#if DEBUG
import XCTest
@testable import RemoteKeyboardCore

final class MeasureTimelineTests: XCTestCase {
    private func micros(_ seconds: Double) -> UInt64 { UInt64(seconds * 1_000_000) }

    // MARK: M5

    func testM5PhasesAreFixedInTime() {
        XCTAssertEqual(M5Timeline.baselineSeconds, 20)
        XCTAssertEqual(M5Timeline.loadSeconds, 60)
        XCTAssertEqual(M5Timeline.recoverySeconds, 30)
        XCTAssertEqual(M5Timeline.phase(atElapsedMicros: 0), .baseline)
        XCTAssertEqual(M5Timeline.phase(atElapsedMicros: micros(19.999)), .baseline)
        XCTAssertEqual(M5Timeline.phase(atElapsedMicros: micros(20)), .load)
        XCTAssertEqual(M5Timeline.phase(atElapsedMicros: micros(79.999)), .load)
        XCTAssertEqual(M5Timeline.phase(atElapsedMicros: micros(80)), .recovery)
        XCTAssertEqual(M5Timeline.phase(atElapsedMicros: micros(109.999)), .recovery)
        XCTAssertNil(M5Timeline.phase(atElapsedMicros: micros(110)), "the run is over")
        XCTAssertEqual(M5Timeline.stopTextAtMicros, micros(80))
    }

    func testM5IsInvalidWhenAnyPhaseHasFewerThanThirtySamples() {
        XCTAssertEqual(M5Timeline.minimumSamplesPerPhase, 30)
        XCTAssertTrue(M5Timeline.isValid(counts: [.baseline: 30, .load: 30, .recovery: 30]))
        XCTAssertFalse(M5Timeline.isValid(counts: [.baseline: 400, .load: 400, .recovery: 29]))
        XCTAssertFalse(M5Timeline.isValid(counts: [.baseline: 400, .load: 400]), "a phase with no sample is invalid")
        XCTAssertFalse(M5Timeline.isValid(counts: [:]))
    }

    func testM5RecoveryIsTheStartOfTheFirstRunOfSamplesAtOrBelowBaselineP95() {
        var samples: [(sentMicros: UInt64, rttMs: Double)] = []
        // After the queue drained at t = 1,000,000, the round trip stays high until t = 1,400,000.
        for step in 0..<40 {
            let sent = UInt64(1_000_000 + step * 20_000)
            samples.append((sent, sent < 1_400_000 ? 300 : 40))
        }
        let recover = M5Timeline.recoverMicros(samples: samples, drainedAtMicros: 1_000_000, baselineP95Ms: 90)
        XCTAssertEqual(recover, 400_000)
    }

    func testM5RecoveryIgnoresALuckySingleSampleAndSamplesBeforeTheDrain() {
        var samples: [(sentMicros: UInt64, rttMs: Double)] = [(500_000, 10)]   // before the drain
        for step in 0..<40 {
            let sent = UInt64(1_000_000 + step * 20_000)
            // One good sample at step 3, then bad again until step 20.
            samples.append((sent, step < 20 && step != 3 ? 300 : 40))
        }
        XCTAssertEqual(M5Timeline.recoverMicros(samples: samples, drainedAtMicros: 1_000_000, baselineP95Ms: 90), 400_000)
    }

    func testM5RecoveryIsNilWhenTheRoundTripNeverComesBack() {
        let samples = (0..<30).map { (sentMicros: UInt64(1_000_000 + $0 * 20_000), rttMs: 300.0) }
        XCTAssertNil(M5Timeline.recoverMicros(samples: samples, drainedAtMicros: 1_000_000, baselineP95Ms: 90))
        XCTAssertNil(M5Timeline.recoverMicros(samples: [], drainedAtMicros: 0, baselineP95Ms: 90))
    }

    func testM5RecoveryNeedsBaselineP95() {
        let samples = (0..<30).map { (sentMicros: UInt64(1_000_000 + $0 * 20_000), rttMs: 40.0) }
        XCTAssertNil(M5Timeline.recoverMicros(samples: samples, drainedAtMicros: 1_000_000, baselineP95Ms: .nan))
    }

    func testM5DrainTimeIsClampedAtZero() {
        XCTAssertEqual(M5Timeline.drainMicros(textStoppedAt: 100, queueEmptyAt: 4_100), 4_000)
        XCTAssertEqual(M5Timeline.drainMicros(textStoppedAt: 100, queueEmptyAt: 50), 0)
    }

    // MARK: M7

    func testM7IterationStages() {
        XCTAssertEqual(ModeSwitchPlan.baselineSeconds, 10)
        XCTAssertEqual(ModeSwitchPlan.trackpadSeconds, 10)
        XCTAssertEqual(ModeSwitchPlan.defaultRuns, 20)
        XCTAssertEqual(ModeSwitchPlan.stage(atIterationMicros: 0), .baseline)
        XCTAssertEqual(ModeSwitchPlan.stage(atIterationMicros: micros(9.999)), .baseline)
        XCTAssertEqual(ModeSwitchPlan.stage(atIterationMicros: micros(10)), .trackpad)
        XCTAssertEqual(ModeSwitchPlan.stage(atIterationMicros: micros(19.999)), .trackpad)
        XCTAssertEqual(ModeSwitchPlan.stage(atIterationMicros: micros(20)), .rest)
        XCTAssertNil(ModeSwitchPlan.stage(atIterationMicros: micros(20 + Double(ModeSwitchPlan.restSeconds))))
    }

    // MARK: M8

    func testM8StreamsOverTenSeconds() {
        var streams = M8Streams()
        var counts: [MeasurePayload.Kind: Int] = [:]
        var time: UInt64 = 0
        while time < 10_000_000 {
            for kind in streams.due(atElapsedMicros: time) { counts[kind, default: 0] += 1 }
            time += 1_000   // a 1 kHz tick: finer than any stream
        }
        XCTAssertEqual(counts[.heartbeat], 100, "every 100 ms")
        XCTAssertEqual(counts[.rtt], 5, "every 2 seconds, the first at once")
        // 60 Hz, doubled for the one second at the end of each 5-second cycle: 8 s x 60 + 2 s x 120 = 720.
        XCTAssertEqual(Double(counts[.cursor] ?? 0), 720, accuracy: 4)
    }

    func testM8ScrollBurstIsTheLastSecondOfEveryFive() {
        XCTAssertFalse(M8Streams.isScrollBurst(atElapsedMicros: 0))
        XCTAssertFalse(M8Streams.isScrollBurst(atElapsedMicros: micros(3.999)))
        XCTAssertTrue(M8Streams.isScrollBurst(atElapsedMicros: micros(4)))
        XCTAssertTrue(M8Streams.isScrollBurst(atElapsedMicros: micros(4.999)))
        XCTAssertFalse(M8Streams.isScrollBurst(atElapsedMicros: micros(5)))
        XCTAssertTrue(M8Streams.isScrollBurst(atElapsedMicros: micros(9.5)))
    }

    func testM8ALateTickDoesNotBurstOutMissedPackets() {
        var streams = M8Streams()
        _ = streams.due(atElapsedMicros: 0)
        // The tick was held up for a whole second: at most one packet per kind is due, and the schedule carries on from now.
        let late = streams.due(atElapsedMicros: 1_000_000)
        XCTAssertEqual(late.filter { $0 == .cursor }.count, 1)
        XCTAssertEqual(late.filter { $0 == .heartbeat }.count, 1)
        XCTAssertTrue(streams.due(atElapsedMicros: 1_001_000).isEmpty)
    }

    func testPacerFirstQuestionIsYesThenFixedSteps() {
        var pacer = Pacer()
        XCTAssertTrue(pacer.due(atMicros: 1_000, interval: 10_000))
        XCTAssertFalse(pacer.due(atMicros: 10_999, interval: 10_000))
        XCTAssertTrue(pacer.due(atMicros: 11_003, interval: 10_000), "a little late")
        // The next deadline is 21,000, not 21,003: lateness does not pile up.
        XCTAssertFalse(pacer.due(atMicros: 20_999, interval: 10_000))
        XCTAssertTrue(pacer.due(atMicros: 21_000, interval: 10_000))
    }

    func testPacerOneTickAtATimeAfterAHoldUp() {
        var pacer = Pacer()
        XCTAssertTrue(pacer.due(atMicros: 0, interval: 10_000))
        XCTAssertTrue(pacer.due(atMicros: 500_000, interval: 10_000))
        XCTAssertFalse(pacer.due(atMicros: 500_001, interval: 10_000), "no burst of the missed packets")
        XCTAssertTrue(pacer.due(atMicros: 510_000, interval: 10_000))
    }

    // MARK: Frames per second (M7)

    func testFramesPerSecondCountsOnlySecondsWhileTheTextWasWaiting() {
        // Window starts at 0. Frames at: 3 in second 0, 2 in second 1, 1 in second 2, then the queue is empty at 2.9 s.
        let times: [UInt64] = [100_000, 400_000, 900_000, 1_100_000, 1_900_000, 2_900_000]
        let summary = FrameRate.summarize(frameMicros: times, windowStartMicros: 0, windowSeconds: 10, queueEmptyAtMicros: 2_900_000)
        XCTAssertEqual(summary.perSecond, [3, 2, 1])
        XCTAssertEqual(summary.minPerSecond, 1)
        XCTAssertEqual(summary.starvedSeconds, 0)
    }

    func testFramesPerSecondFlagsAStarvedSecond() {
        let times: [UInt64] = [100_000, 3_100_000]
        let summary = FrameRate.summarize(frameMicros: times, windowStartMicros: 0, windowSeconds: 10, queueEmptyAtMicros: 3_100_000)
        XCTAssertEqual(summary.perSecond, [1, 0, 0, 1])
        XCTAssertEqual(summary.minPerSecond, 0)
        XCTAssertEqual(summary.starvedSeconds, 2)
    }

    func testFramesPerSecondWhenTheQueueNeverEmptiesCoversTheWholeWindow() {
        let times = (0..<20).map { UInt64($0) * 400_000 }   // 2.5 per second for 8 seconds
        let summary = FrameRate.summarize(frameMicros: times, windowStartMicros: 0, windowSeconds: 4, queueEmptyAtMicros: nil)
        XCTAssertEqual(summary.perSecond.count, 4)
        XCTAssertEqual(summary.perSecond, [3, 2, 3, 2])
        XCTAssertEqual(summary.starvedSeconds, 0)
    }

    func testFramesPerSecondIgnoresFramesOutsideTheWindowAndHandlesNone() {
        let none = FrameRate.summarize(frameMicros: [], windowStartMicros: 5_000_000, windowSeconds: 10, queueEmptyAtMicros: 5_000_000)
        XCTAssertEqual(none.perSecond, [])
        XCTAssertNil(none.minPerSecond)
        XCTAssertEqual(none.starvedSeconds, 0)
        let outside = FrameRate.summarize(frameMicros: [1_000_000, 99_000_000], windowStartMicros: 5_000_000, windowSeconds: 10, queueEmptyAtMicros: nil)
        XCTAssertEqual(outside.perSecond, Array(repeating: 0, count: 10))
        XCTAssertEqual(outside.starvedSeconds, 10)
    }
}
#endif
