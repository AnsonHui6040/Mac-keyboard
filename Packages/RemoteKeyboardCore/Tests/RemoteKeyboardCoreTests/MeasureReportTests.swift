#if DEBUG
import XCTest
@testable import RemoteKeyboardCore

/// The wording of the result lines: one-way numbers are estimates, the watchdog result is a simulated release, and the
/// click number is a proxy round trip.
final class MeasureReportTests: XCTestCase {
    private func analysis() throws -> ClockOffsetAnalysis {
        let samples = (0..<300).map { index -> ClockOffsetSample in
            let send = UInt64(1_000_000 + index * 100_000)
            return ClockOffsetSample(phoneSendMicros: send, macRecvMicros: send + 5_000 + 2_000_000, phoneRecvMicros: send + 10_000)
        }
        return try XCTUnwrap(ClockOffsetEstimator.analyze(samples))
    }

    private func tokens(_ line: String) -> [String: String] {
        var result: [String: String] = [:]
        for part in line.split(separator: " ") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
        }
        return result
    }

    func testM3aIsTheRoundTrip() {
        let line = MeasureReport.m3a(rtt: LatencyStats(samplesMs: [40, 50, 60, 70, 80]))
        XCTAssertTrue(line.hasPrefix("M3a "))
        let values = tokens(line)
        XCTAssertEqual(values["count"], "5")
        XCTAssertEqual(values["p50_ms"], "60.0")
        XCTAssertNotNil(values["p95_ms"])
        XCTAssertNotNil(values["p99_ms"])
        XCTAssertNotNil(values["jitter_ms"])
    }

    func testM3bIsCoverageAndSkips() {
        let line = MeasureReport.m3b(
            sent: 200, replies: 50, refused: 3, superseded: 4, arrivalSdMs: 12.34, holdP50Ms: 0.4, waitP50Ms: 0.1, waitP95Ms: 2)
        XCTAssertTrue(line.hasPrefix("M3b "))
        let values = tokens(line)
        XCTAssertEqual(values["coverage_pct"], "25.0")
        XCTAssertEqual(values["skipped"], "150")
        XCTAssertEqual(values["skipped_pct"], "75.0")
        XCTAssertEqual(values["sent"], "200")
        XCTAssertEqual(values["refused"], "3")
        XCTAssertEqual(values["superseded"], "4")
    }

    func testM3bWithNothingSent() {
        let values = tokens(MeasureReport.m3b(sent: 0, replies: 0, refused: 0, superseded: 0, arrivalSdMs: .nan, holdP50Ms: .nan, waitP50Ms: .nan, waitP95Ms: .nan))
        XCTAssertEqual(values["coverage_pct"], "nan")
        XCTAssertEqual(values["skipped_pct"], "nan")
    }

    func testM3cLabelsEveryOneWayNumberAsAnEstimate() throws {
        let line = MeasureReport.m3c(try analysis())
        XCTAssertTrue(line.hasPrefix("M3c 估計單程 "))
        let values = tokens(line)
        for key in ["est_oneway_p50_ms", "est_oneway_p95_ms", "est_oneway_p99_ms"] { XCTAssertNotNil(values[key], key) }
        XCTAssertEqual(try XCTUnwrap(Double(values["est_oneway_p50_ms"] ?? "")), 5, accuracy: 0.1)
        XCTAssertEqual(values["assumption"], "symmetric")
        XCTAssertNotNil(values["offset_est_us"])
        XCTAssertNotNil(values["drift_us_per_min"])
        XCTAssertNotNil(values["error_bound_ms"])
        // Half of the 10 ms minimum round trip, plus 100 ppm over the 29.9 s span, because no drift could be measured.
        XCTAssertEqual(try XCTUnwrap(Double(values["error_bound_ms"] ?? "")), 5 + 2.99, accuracy: 0.2)
        XCTAssertEqual(values["drift_measured"], "false")
        XCTAssertFalse(values.keys.contains { $0.contains("oneway") && !$0.hasPrefix("est_") }, "no one-way key without est_")
    }

    func testM3cWithoutUsableReplies() {
        let line = MeasureReport.m3c(nil)
        XCTAssertTrue(line.hasPrefix("M3c 估計單程 "))
        XCTAssertEqual(tokens(line)["est_oneway_p50_ms"], "nan")
        XCTAssertEqual(tokens(line)["assumption"], "symmetric")
    }

    func testCalibrationLineCarriesTheModel() throws {
        let line = MeasureReport.calibration(try analysis(), label: "CAL")
        XCTAssertTrue(line.hasPrefix("CAL "))
        let values = tokens(line)
        for key in ["offset_est_us", "ref_phone_us", "drift_us_per_min", "error_bound_ms", "samples", "assumption"] {
            XCTAssertNotNil(values[key], key)
        }
    }

    func testLatencyTagOnEveryLine() {
        XCTAssertEqual(
            MeasureReport.tag("M3a count=1", latency: .low, carryover: nil),
            "M3a count=1 latency_requested=low latency_confirmed=unconfirmed")
        XCTAssertEqual(
            MeasureReport.tag("M2 packet=41", latency: .none, carryover: "low"),
            "M2 packet=41 latency_requested=none latency_confirmed=unconfirmed latency_carryover=low")
        XCTAssertEqual(
            MeasureReport.tag("M2 packet=41", latency: .medium, carryover: nil),
            "M2 packet=41 latency_requested=medium latency_confirmed=unconfirmed")
    }

    func testClickProxyAndSimulatedReleaseWording() {
        let click = MeasureReport.clickProxy(rtt: LatencyStats(samplesMs: [30, 40, 50, 60, 70]))
        XCTAssertTrue(click.hasPrefix("M8 點擊代理 RTT "))
        XCTAssertEqual(tokens(click)["click_proxy_rtt_p50_ms"], "50.0")
        XCTAssertNotNil(tokens(click)["click_proxy_rtt_p95_ms"])
        XCTAssertEqual(tokens(click)["count"], "5")
        let release = MeasureReport.simulatedReleasePending(item: "M6")
        XCTAssertTrue(release.hasPrefix("M6 模擬誤釋放 "))
        XCTAssertEqual(tokens(release)["simulated_release"], "pending_mac_csv")
        for line in [click, release] {
            XCTAssertFalse(line.contains("誤放開"))
            XCTAssertFalse(line.contains("wouldRelease"))
            XCTAssertFalse(line.contains("click_rtt"))
        }
    }

    func testNumberFormat() {
        XCTAssertEqual(MeasureReport.number(12.345), "12.3")
        XCTAssertEqual(MeasureReport.number(.nan), "nan")
    }
}
#endif
