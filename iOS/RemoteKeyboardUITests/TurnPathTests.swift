import XCTest

/// Plain logic tests for TurnPath (no app, no device input).
final class TurnPathTests: XCTestCase {
    private let box = CGRect(x: 40, y: 100, width: 300, height: 300)
    private var start: CGPoint { CGPoint(x: box.midX, y: box.midY) }

    private func path(_ seed: UInt64) -> [CGPoint] {
        TurnPath.make(seed: seed, segments: 20, segmentLength: 40, box: box, start: start)
    }

    func testSameSeedGivesTheSamePath() {
        XCTAssertEqual(path(7), path(7))
        XCTAssertNotEqual(path(7), path(8))
    }

    func testTwentySegments() {
        XCTAssertEqual(path(1).count, 20)
    }

    func testEveryPointStaysInsideTheBox() {
        for seed in UInt64(1)...200 {
            for point in path(seed) { XCTAssertTrue(box.contains(point), "seed \(seed)") }
        }
    }

    func testEveryStepIsExactlyOneSegmentAlongOneAxis() {
        for seed in UInt64(1)...200 {
            var previous = start
            for point in path(seed) {
                let dx = abs(point.x - previous.x), dy = abs(point.y - previous.y)
                XCTAssertTrue((dx == 40 && dy == 0) || (dx == 0 && dy == 40), "seed \(seed)")
                previous = point
            }
        }
    }

    func testDirectionsAreNotAllTheSame() {
        for seed in UInt64(1)...200 {
            var previous = start
            var seen = Set<String>()
            for point in path(seed) {
                seen.insert("\(point.x - previous.x),\(point.y - previous.y)")
                previous = point
            }
            XCTAssertGreaterThan(seen.count, 1, "seed \(seed)")
        }
    }

    func testSamplesAreContinuousAndEndOnEverySegmentEnd() {
        let ends = path(3)
        let s = TurnPath.samples(start: start, ends: ends, segmentDuration: 0.1)
        XCTAssertEqual(s.points.count, s.offsets.count)
        XCTAssertEqual(s.offsets.first, 0)
        XCTAssertEqual(s.offsets.last!, 2.0, accuracy: 1e-9)
        XCTAssertEqual(s.points.last, ends.last)
        for i in 1..<s.offsets.count { XCTAssertGreaterThanOrEqual(s.offsets[i], s.offsets[i - 1]) }
        for i in 1..<s.points.count {
            let dx = s.points[i].x - s.points[i - 1].x, dy = s.points[i].y - s.points[i - 1].y
            XCTAssertLessThanOrEqual((dx * dx + dy * dy).squareRoot(), 40.0 / 6.0 + 1e-6)
        }
    }
}
