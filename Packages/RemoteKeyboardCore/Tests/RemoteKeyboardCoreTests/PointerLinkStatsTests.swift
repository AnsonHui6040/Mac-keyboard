import XCTest
@testable import RemoteKeyboardCore

final class PointerLinkStatsTests: XCTestCase {
    private let ms: UInt64 = 1_000

    func testTooFewSamplesGiveNothing() {
        var stats = PointerLinkStats()
        for i in 0..<19 { stats.record(arrivalMicros: UInt64(i) * 15 * ms, dtTenths: 150) }
        XCTAssertNil(stats.snapshot(nowMicros: 19 * 15 * ms))
        stats.record(arrivalMicros: 19 * 15 * ms, dtTenths: 150)
        XCTAssertNotNil(stats.snapshot(nowMicros: 19 * 15 * ms))
    }

    func testAFixedFifteenMillisecondIntervalGivesRateAndPercentiles() throws {
        var stats = PointerLinkStats()
        for i in 0..<400 { stats.record(arrivalMicros: 1_000_000 + UInt64(i) * 15 * ms, dtTenths: 150) }
        let s = try XCTUnwrap(stats.snapshot(nowMicros: 1_000_000 + 399 * 15 * ms))
        XCTAssertEqual(s.packetsPerSecond, 66.7, accuracy: 1)
        XCTAssertEqual(s.arrivalP50Millis, 15, accuracy: 0.5)
        XCTAssertEqual(s.arrivalP95Millis, 15, accuracy: 0.5)
        XCTAssertEqual(s.estimatedConnectionIntervalMillis, 15, accuracy: 0.5)
        XCTAssertEqual(s.backlogGrowthMillis, 0, accuracy: 0.5)
    }

    func testPacketsInBunchesGiveTheBunchSpacingAsTheEstimatedInterval() throws {
        var stats = PointerLinkStats()
        for i in 0..<60 {
            let base = 1_000_000 + UInt64(i) * 30 * ms
            stats.record(arrivalMicros: base, dtTenths: 150)
            stats.record(arrivalMicros: base + 1 * ms, dtTenths: 150)
        }
        let s = try XCTUnwrap(stats.snapshot(nowMicros: 1_000_000 + 59 * 30 * ms + ms))
        XCTAssertEqual(s.estimatedConnectionIntervalMillis, 30, accuracy: 0.5)
        XCTAssertEqual(s.arrivalP50Millis, 1, accuracy: 0.5, "the measured gaps are still per packet")
    }

    func testBacklogGrowthIsArrivalTimeMinusThePhoneTimeline() throws {
        var stats = PointerLinkStats()
        // The phone made a packet every 10 ms (dt 100), the Mac gets them every 12 ms: 2 ms more behind per packet.
        for i in 0..<50 { stats.record(arrivalMicros: 1_000_000 + UInt64(i) * 12 * ms, dtTenths: 100) }
        let s = try XCTUnwrap(stats.snapshot(nowMicros: 1_000_000 + 49 * 12 * ms))
        XCTAssertEqual(s.backlogGrowthMillis, 98, accuracy: 1)
    }

    func testANewStrokeAfterAGapOverOneHundredMillisecondsResetsTheBaseline() throws {
        var stats = PointerLinkStats()
        for i in 0..<30 { stats.record(arrivalMicros: 1_000_000 + UInt64(i) * 12 * ms, dtTenths: 100) }
        let restart = 1_000_000 + 29 * 12 * ms + 500 * ms
        for i in 0..<30 { stats.record(arrivalMicros: restart + UInt64(i) * 10 * ms, dtTenths: 100) }
        let s = try XCTUnwrap(stats.snapshot(nowMicros: restart + 29 * 10 * ms))
        XCTAssertEqual(s.backlogGrowthMillis, 0, accuracy: 1, "only the new stroke counts, and it keeps up")
    }

    func testSamplesOlderThanFiveSecondsAreForgotten() {
        var stats = PointerLinkStats()
        for i in 0..<100 { stats.record(arrivalMicros: UInt64(i) * 15 * ms, dtTenths: 150) }
        XCTAssertNotNil(stats.snapshot(nowMicros: 99 * 15 * ms))
        XCTAssertNil(stats.snapshot(nowMicros: 99 * 15 * ms + 6_000_000), "all of it fell out of the window")
    }

    func testResetEmptiesIt() {
        var stats = PointerLinkStats()
        for i in 0..<100 { stats.record(arrivalMicros: UInt64(i) * 15 * ms, dtTenths: 150) }
        stats.reset()
        XCTAssertNil(stats.snapshot(nowMicros: 99 * 15 * ms))
    }

    func testSummaryLinesAreInTaiwaneseTraditionalChineseAndMarkEstimates() throws {
        var stats = PointerLinkStats()
        for i in 0..<400 { stats.record(arrivalMicros: 1_000_000 + UInt64(i) * 15 * ms, dtTenths: 150) }
        let s = try XCTUnwrap(stats.snapshot(nowMicros: 1_000_000 + 399 * 15 * ms))
        XCTAssertEqual(s.lines, ["每秒封包 67", "到達間隔 P50 15 ms，P95 15 ms", "推估連線間隔 15 ms", "推估積壓 0 ms"])
        XCTAssertFalse(s.lines.joined().contains("・"))
    }
}
