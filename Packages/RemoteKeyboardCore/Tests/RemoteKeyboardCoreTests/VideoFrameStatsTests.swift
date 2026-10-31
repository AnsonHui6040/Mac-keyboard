import XCTest
@testable import RemoteKeyboardCore

final class VideoFrameStatsTests: XCTestCase {
    func testFramesToMs() {
        let stats = VideoFrameStats(fps: 240, rows: [(t0: 100, t2: 104, t5p: 108, t6: 112)])
        XCTAssertEqual(stats.e2e.p50, 50.0, accuracy: 1e-9)
        XCTAssertEqual(stats.transportToDisplay?.p50 ?? .nan, 8 * 1000.0 / 240, accuracy: 1e-9)
        XCTAssertEqual(stats.macDisplay?.p50 ?? .nan, 4 * 1000.0 / 240, accuracy: 1e-9)
        XCTAssertEqual(stats.quantizationErrorMs, 1000.0 / 240, accuracy: 1e-9)
    }

    func testRowsWithoutOptionalPointsAreLeftOutOfThoseStatsOnly() {
        let stats = VideoFrameStats(fps: 240, rows: [
            (t0: 0, t2: 3, t5p: nil, t6: 12),
            (t0: 100, t2: nil, t5p: 110, t6: 112)
        ])
        XCTAssertEqual(stats.e2e.count, 2)
        XCTAssertEqual(stats.transportToDisplay?.count, 1)
        XCTAssertEqual(stats.macDisplay?.count, 1)
    }

    func testOptionalStatsAreNilWhenNoRowHasThePoint() {
        let stats = VideoFrameStats(fps: 120, rows: [(t0: 0, t2: nil, t5p: nil, t6: 6)])
        XCTAssertNil(stats.transportToDisplay)
        XCTAssertNil(stats.macDisplay)
        XCTAssertEqual(stats.e2e.p50, 50.0, accuracy: 1e-9)
    }

    func testBorderlineWithinTwoFrames() {
        // 240 fps: two frames are 8.33 ms.
        func stats(p95Ms: Double) -> VideoFrameStats {
            let frames = Int((p95Ms * 240 / 1000).rounded())
            return VideoFrameStats(fps: 240, rows: [(t0: 0, t2: nil, t5p: nil, t6: frames)])
        }
        XCTAssertTrue(stats(p95Ms: 55).isBorderline(target: 60))
        XCTAssertFalse(stats(p95Ms: 50).isBorderline(target: 60))
        XCTAssertTrue(stats(p95Ms: 68).isBorderline(target: 60))
        XCTAssertFalse(stats(p95Ms: 70).isBorderline(target: 60))
    }

    func testEmptyRows() {
        let stats = VideoFrameStats(fps: 240, rows: [])
        XCTAssertEqual(stats.e2e.count, 0)
        XCTAssertFalse(stats.isBorderline(target: 60))
    }
}
