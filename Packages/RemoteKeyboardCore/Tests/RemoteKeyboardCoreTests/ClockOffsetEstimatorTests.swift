#if DEBUG
import XCTest
@testable import RemoteKeyboardCore

/// M3c: the clock offset between the two devices is estimated from round trips, never measured. Every test builds the
/// samples from a known truth, so the estimator's answer, its stated assumptions and its error bound can be checked.
final class ClockOffsetEstimatorTests: XCTestCase {
    /// A small deterministic generator, so the jitter is the same on every run.
    private struct Lcg {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 33) / Double(1 << 31)
        }
    }

    private struct Truth {
        var sample: ClockOffsetSample
        var forwardMicros: Double
    }

    /// Mac clock = phone clock × (1 + driftPpm / 1e6) + offsetMicros. `forward` and `back` give the one-way delays of sample `i`.
    private func makeSamples(
        count: Int, spacingMicros: UInt64, offsetMicros: Double, driftPpm: Double = 0,
        forward: (Int, inout Lcg) -> Double, back: (Int, Double, inout Lcg) -> Double, holdMicros: UInt64 = 0
    ) -> [Truth] {
        var rng = Lcg(state: 42)
        let start: UInt64 = 5_000_000
        return (0..<count).map { index in
            let send = start + UInt64(index) * spacingMicros
            let d1 = forward(index, &rng)
            let d2 = back(index, d1, &rng)
            let phoneAtMacRecv = Double(send) + d1
            let macRecv = phoneAtMacRecv * (1 + driftPpm / 1e6) + offsetMicros
            let recv = Double(send) + d1 + Double(holdMicros) + d2
            let sample = ClockOffsetSample(
                phoneSendMicros: send, macRecvMicros: UInt64(macRecv.rounded()), phoneRecvMicros: UInt64(recv.rounded()),
                macHoldMicros: holdMicros)
            return Truth(sample: sample, forwardMicros: d1)
        }
    }

    func testRecoversAKnownOffsetWithSymmetricDelays() throws {
        let offset = 5_123_456.0
        // Symmetric: the way back takes as long as the way there, sample by sample.
        let truths = makeSamples(
            count: 600, spacingMicros: 100_000, offsetMicros: offset,
            forward: { _, rng in 3_000 + rng.next() * 6_000 }, back: { _, d1, _ in d1 }, holdMicros: 200)
        let samples = truths.map(\.sample)
        let analysis = try XCTUnwrap(ClockOffsetEstimator.analyze(samples))
        let atFirst = analysis.offsetMicros(atPhoneMicros: Double(samples[0].phoneSendMicros))
        XCTAssertEqual(atFirst, offset, accuracy: 1_000, "recovered within 1 ms")
        XCTAssertEqual(analysis.estimatedOneWayMicros.count, samples.count)
        for (estimated, truth) in zip(analysis.estimatedOneWayMicros, truths) {
            XCTAssertEqual(estimated, truth.forwardMicros, accuracy: 1_000)
        }
        XCTAssertTrue(analysis.assumptions.symmetricDelay)
        XCTAssertEqual(analysis.errorBound.minRttHalfMicros, analysis.errorBound.minRttMicros / 2, accuracy: 0.001)
        XCTAssertGreaterThan(analysis.errorBound.totalMicros, 0)
    }

    func testAsymmetricDelayStaysInsideTheErrorBound() throws {
        let offset = -3_000_000.0
        // 3 ms there, 9 ms back (plus up to 3 ms of jitter each way): the symmetric assumption is wrong by 3 ms.
        let truths = makeSamples(
            count: 600, spacingMicros: 100_000, offsetMicros: offset,
            forward: { _, rng in 3_000 + rng.next() * 3_000 }, back: { _, _, rng in 9_000 + rng.next() * 3_000 })
        let analysis = try XCTUnwrap(ClockOffsetEstimator.analyze(truths.map(\.sample)))
        let bound = analysis.errorBound.totalMicros
        let estimatedOffset = analysis.offsetMicros(atPhoneMicros: Double(truths[0].sample.phoneSendMicros))
        XCTAssertLessThanOrEqual(abs(estimatedOffset - offset), bound, "the true offset lies within ± the error bound")
        var worst = 0.0
        for (estimated, truth) in zip(analysis.estimatedOneWayMicros, truths) {
            worst = max(worst, abs(estimated - truth.forwardMicros))
        }
        XCTAssertLessThanOrEqual(worst, bound, "every true one-way delay lies within the bound of its estimate")
        XCTAssertGreaterThan(worst, 1_000, "the asymmetry really does show up as an error; the bound is not trivially tight")
        XCTAssertEqual(analysis.errorBound.minRttMicros, 12_000, accuracy: 1_500)
    }

    func testLinearDriftIsMeasuredAndCompensated() throws {
        let offset = 2_000_000.0
        let driftPpm = 50.0
        // 50 ppm is 3,000 µs per minute; the run lasts 3 minutes.
        let truths = makeSamples(
            count: 1_800, spacingMicros: 100_000, offsetMicros: offset, driftPpm: driftPpm,
            forward: { _, rng in 4_000 + rng.next() * 3_000 }, back: { _, d1, _ in d1 })
        let samples = truths.map(\.sample)
        let analysis = try XCTUnwrap(ClockOffsetEstimator.analyze(samples))
        XCTAssertTrue(analysis.assumptions.driftMeasured)
        XCTAssertEqual(analysis.assumptions.driftMicrosPerMinute, 3_000, accuracy: 150)
        XCTAssertEqual(analysis.assumptions.spanSeconds, 180, accuracy: 1)
        // Compensated: the last samples are as good as the first, where a constant offset would be 9 ms off.
        for (estimated, truth) in zip(analysis.estimatedOneWayMicros, truths).suffix(100) {
            XCTAssertEqual(estimated, truth.forwardMicros, accuracy: 500)
        }
        let atStart = analysis.offsetMicros(atPhoneMicros: Double(samples[0].phoneSendMicros))
        let atEnd = analysis.offsetMicros(atPhoneMicros: Double(samples[1_799].phoneSendMicros))
        XCTAssertEqual(atEnd - atStart, 9_000, accuracy: 500)
    }

    func testAShortRunDoesNotClaimADrift() throws {
        let truths = makeSamples(
            count: 100, spacingMicros: 100_000, offsetMicros: 1_000_000, driftPpm: 50,
            forward: { _, _ in 5_000 }, back: { _, _, _ in 5_000 })
        let analysis = try XCTUnwrap(ClockOffsetEstimator.analyze(truths.map(\.sample)))
        XCTAssertFalse(analysis.assumptions.driftMeasured, "10 seconds is too short to tell a drift from noise")
        XCTAssertEqual(analysis.assumptions.driftMicrosPerMinute, 0)
    }

    /// M7 has a 5 s calibration at the start and another at the end, with minutes of nothing in between.
    private func twoClusters(gapSeconds: Double, driftPpm: Double) -> [Truth] {
        var rng = Lcg(state: 7)
        let clusterCount = 300   // 5 s at 60 Hz
        var truths: [Truth] = []
        for cluster in 0..<2 {
            let start = 5_000_000 + UInt64(Double(cluster) * (5 + gapSeconds) * 1_000_000)
            for index in 0..<clusterCount {
                let send = start + UInt64(index) * 16_667
                let d1 = 4_000 + rng.next() * 1_000
                let d2 = 4_000 + rng.next() * 1_000
                let macRecv = (Double(send) + d1) * (1 + driftPpm / 1e6) + 2_000_000
                let recv = Double(send) + d1 + d2
                truths.append(Truth(
                    sample: ClockOffsetSample(phoneSendMicros: send, macRecvMicros: UInt64(macRecv.rounded()), phoneRecvMicros: UInt64(recv.rounded())),
                    forwardMicros: d1))
            }
        }
        return truths
    }

    func testTwoCalibrationClustersFarApartGiveTheDrift() throws {
        let truths = twoClusters(gapSeconds: 400, driftPpm: 50)
        let analysis = try XCTUnwrap(ClockOffsetEstimator.analyze(truths.map(\.sample)))
        XCTAssertTrue(analysis.assumptions.driftMeasured, "two anchors 400 s apart are enough")
        XCTAssertEqual(analysis.assumptions.driftMicrosPerMinute, 3_000, accuracy: 300, "within 5 ppm of the 50 ppm")
        XCTAssertEqual(analysis.errorBound.driftAllowanceMicros, 0, "a measured drift needs no allowance")
        var worst = 0.0
        for (estimated, truth) in zip(analysis.estimatedOneWayMicros, truths) {
            worst = max(worst, abs(estimated - truth.forwardMicros))
        }
        XCTAssertLessThanOrEqual(worst, analysis.errorBound.totalMicros)
        XCTAssertLessThan(worst, 2_500, "and the drift of about 20 ms over the run is compensated")
    }

    func testAnUnmeasuredLongSpanAddsTheConservativeDriftAllowance() throws {
        // 25 s of samples: too short to fit a drift, long enough that 100 ppm would matter.
        let truths = makeSamples(
            count: 250, spacingMicros: 100_000, offsetMicros: 1_000_000,
            forward: { _, _ in 5_000 }, back: { _, d1, _ in d1 })
        let analysis = try XCTUnwrap(ClockOffsetEstimator.analyze(truths.map(\.sample)))
        XCTAssertFalse(analysis.assumptions.driftMeasured)
        XCTAssertEqual(analysis.assumptions.spanSeconds, 24.9, accuracy: 0.1)
        XCTAssertEqual(analysis.errorBound.driftAllowanceMicros, 24.9 * 100, accuracy: 20, "span x 100 ppm")
        XCTAssertEqual(
            analysis.errorBound.totalMicros,
            analysis.errorBound.minRttHalfMicros + analysis.errorBound.residualMicros + analysis.errorBound.driftAllowanceMicros,
            accuracy: 0.001)
    }

    func testTwoClustersTooCloseTogetherAreNotADrift() throws {
        let truths = twoClusters(gapSeconds: 12, driftPpm: 50)
        let analysis = try XCTUnwrap(ClockOffsetEstimator.analyze(truths.map(\.sample)))
        // The two clusters are a gap apart that is below the clustering limit: one group, span 22 s, nothing to fit.
        XCTAssertFalse(analysis.assumptions.driftMeasured)
        XCTAssertGreaterThan(analysis.errorBound.driftAllowanceMicros, 0)
    }

    func testClustersSeparatedByMoreThanTheGapLimitButLessThanThirtySecondsOfAnchorsStayUnmeasured() throws {
        let truths = twoClusters(gapSeconds: 22, driftPpm: 50)
        let analysis = try XCTUnwrap(ClockOffsetEstimator.analyze(truths.map(\.sample)))
        XCTAssertFalse(analysis.assumptions.driftMeasured, "anchors 27 s apart are under the 30 s needed")
        XCTAssertGreaterThan(analysis.errorBound.driftAllowanceMicros, 0)
    }

    func testTheAnchorIsTheMedianOfTheLowestRoundTripsNotOneLuckySample() throws {
        // 200 samples with an offset error of +3 ms (back 10, forward 4); one lucky sample with back 4 (offset error 0, rtt 8 ms).
        var truths = makeSamples(
            count: 200, spacingMicros: 100_000, offsetMicros: 1_000_000,
            forward: { _, _ in 4_000 }, back: { _, _, _ in 10_000 })
        let lucky = makeSamples(count: 1, spacingMicros: 100_000, offsetMicros: 1_000_000, forward: { _, _ in 4_000 }, back: { _, _, _ in 4_000 })
        truths[100] = Truth(sample: ClockOffsetSample(
            phoneSendMicros: truths[100].sample.phoneSendMicros, macRecvMicros: truths[100].sample.macRecvMicros,
            phoneRecvMicros: truths[100].sample.phoneSendMicros + 8_000), forwardMicros: lucky[0].forwardMicros)
        let analysis = try XCTUnwrap(ClockOffsetEstimator.analyze(truths.map(\.sample)))
        XCTAssertEqual(analysis.errorBound.minRttMicros, 8_000, accuracy: 1, "the bound still uses the smallest round trip")
        // 5% of 200 is 10 samples; one lucky sample does not decide the anchor.
        let atFirst = analysis.offsetMicros(atPhoneMicros: Double(truths[0].sample.phoneSendMicros))
        XCTAssertEqual(atFirst, 1_000_000 - 3_000, accuracy: 100, "the anchor sits with the typical low round trips")
    }

    func testNoUsableSamples() {
        XCTAssertNil(ClockOffsetEstimator.analyze([]))
        // A reply that arrived before its probe left, or held longer than the whole round trip, is not a sample.
        let backwards = ClockOffsetSample(phoneSendMicros: 100, macRecvMicros: 5_000, phoneRecvMicros: 50)
        let heldTooLong = ClockOffsetSample(phoneSendMicros: 100, macRecvMicros: 5_000, phoneRecvMicros: 600, macHoldMicros: 900)
        XCTAssertNil(ClockOffsetEstimator.analyze([backwards, heldTooLong]))
    }

    func testTheThreePartsAreSeparateAndTheHoldTimeIsNotDelay() throws {
        // One sample: 4 ms there, 4 ms back, 1 ms held by the Mac. The hold must not count as delay.
        let send: UInt64 = 1_000_000
        let sample = ClockOffsetSample(
            phoneSendMicros: send, macRecvMicros: send + 4_000 + 777_000, phoneRecvMicros: send + 4_000 + 1_000 + 4_000, macHoldMicros: 1_000)
        let analysis = try XCTUnwrap(ClockOffsetEstimator.analyze([sample]))
        XCTAssertEqual(analysis.errorBound.minRttMicros, 8_000, accuracy: 0.001)
        XCTAssertEqual(analysis.offsetMicros(atPhoneMicros: Double(send)), 777_000, accuracy: 0.001)
        XCTAssertEqual(analysis.estimatedOneWayMicros, [4_000])
        XCTAssertEqual(analysis.estimatedOneWayMicros(phoneSendMicros: send, macRecvMicros: send + 777_000 + 6_000), 6_000, accuracy: 0.001)
        XCTAssertEqual(analysis.assumptions.sampleCount, 1)
    }
}
#endif
