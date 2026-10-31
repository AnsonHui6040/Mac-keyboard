import XCTest
@testable import RemoteKeyboardCore

final class LatencyStatsTests: XCTestCase {
    func testStatsPercentiles() {
        let stats = LatencyStats(samplesMs: (1...100).map(Double.init))
        XCTAssertEqual(stats.count, 100)
        XCTAssertEqual(stats.p50, 50.5, accuracy: 1e-9)
        XCTAssertEqual(stats.p95, 95.05, accuracy: 1e-9)
        XCTAssertEqual(stats.p99, 99.01, accuracy: 1e-9)
        XCTAssertEqual(stats.jitterMs, stats.p95 - stats.p50, accuracy: 1e-9)
    }

    func testStatsAreIndependentOfInputOrder() {
        let shuffled = (1...100).map(Double.init).shuffled()
        XCTAssertEqual(LatencyStats(samplesMs: shuffled), LatencyStats(samplesMs: (1...100).map(Double.init)))
    }

    func testStatsEmpty() {
        let stats = LatencyStats(samplesMs: [])
        XCTAssertEqual(stats.count, 0)
        XCTAssertTrue(stats.p50.isNaN)
        XCTAssertTrue(stats.p95.isNaN)
        XCTAssertTrue(stats.p99.isNaN)
        XCTAssertTrue(stats.jitterMs.isNaN)
    }

    func testSingleSample() {
        let stats = LatencyStats(samplesMs: [12.5])
        XCTAssertEqual(stats.p50, 12.5)
        XCTAssertEqual(stats.p99, 12.5)
        XCTAssertEqual(stats.jitterMs, 0)
    }

    func testMeanMaxAndStandardDeviation() {
        let stats = LatencyStats(samplesMs: [2, 4, 4, 4, 5, 5, 7, 9])
        XCTAssertEqual(stats.meanMs, 5, accuracy: 1e-9)
        XCTAssertEqual(stats.maxMs, 9)
        XCTAssertEqual(stats.standardDeviationMs, 2, accuracy: 1e-9)
    }
}
