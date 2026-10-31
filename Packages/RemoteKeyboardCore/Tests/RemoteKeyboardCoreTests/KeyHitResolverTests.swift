import XCTest
@testable import RemoteKeyboardCore

final class KeyHitResolverTests: XCTestCase {
    private let gap = KeyboardMetrics.keyGap
    private let rowGap = KeyboardMetrics.rowGap

    /// Two keys on one row: [0, 40) and [46, 86), 6 pt apart; a second row 12 pt below.
    private var keys: [HitRect] {
        [
            HitRect(x: 0, y: 0, width: 40, height: 40),
            HitRect(x: 40 + gap, y: 0, width: 40, height: 40),
            HitRect(x: 0, y: 40 + rowGap, width: 40, height: 40),
        ]
    }

    func testPointInsideKeyReturnsThatKey() {
        XCTAssertEqual(KeyHitResolver.nearest(to: HitPoint(x: 60, y: 20), in: keys, maxDistance: rowGap), 1)
        XCTAssertEqual(KeyHitResolver.nearest(to: HitPoint(x: 10, y: 60), in: keys, maxDistance: rowGap), 2)
    }

    func testHorizontalGapGoesToTheNearerSide() {
        XCTAssertEqual(KeyHitResolver.nearest(to: HitPoint(x: 41, y: 20), in: keys, maxDistance: rowGap), 0)
        XCTAssertEqual(KeyHitResolver.nearest(to: HitPoint(x: 45, y: 20), in: keys, maxDistance: rowGap), 1)
    }

    func testExactMiddleTakesTheEarlierKey() {
        XCTAssertEqual(KeyHitResolver.nearest(to: HitPoint(x: 43, y: 20), in: keys, maxDistance: rowGap), 0)
    }

    func testRowGapGoesToTheNearerRow() {
        // Gap between y 40 and 52; x 10 is only above/below key 0 and key 2.
        XCTAssertEqual(KeyHitResolver.nearest(to: HitPoint(x: 10, y: 43), in: keys, maxDistance: rowGap), 0)
        XCTAssertEqual(KeyHitResolver.nearest(to: HitPoint(x: 10, y: 49), in: keys, maxDistance: rowGap), 2)
    }

    func testOutsideTheSideEdgesWithinMaxDistance() {
        XCTAssertEqual(KeyHitResolver.nearest(to: HitPoint(x: -3, y: 20), in: keys, maxDistance: rowGap), 0)
        XCTAssertEqual(KeyHitResolver.nearest(to: HitPoint(x: 86 + 12, y: 20), in: keys, maxDistance: rowGap), 1)
    }

    func testBeyondMaxDistanceReturnsNil() {
        XCTAssertNil(KeyHitResolver.nearest(to: HitPoint(x: -12.5, y: 20), in: keys, maxDistance: rowGap))
        XCTAssertNil(KeyHitResolver.nearest(to: HitPoint(x: 20, y: 200), in: keys, maxDistance: rowGap))
    }

    func testEmptyListReturnsNil() {
        XCTAssertNil(KeyHitResolver.nearest(to: HitPoint(x: 0, y: 0), in: [], maxDistance: rowGap))
    }

    func testDefaultMaxDistanceIsOneKeyRowHeight() {
        XCTAssertEqual(KeyHitResolver.defaultMaxDistance, KeyboardMetrics.keyRowHeight)
    }

    /// Row 2 is inset by half a key on each side, so the left edge is about 20 pt from its first key.
    func testIndentedSecondRowEdgeHitsItsFirstKeyNotTheRowAbove() {
        let h = KeyboardMetrics.keyRowHeight, w = 36.0
        let step = w + gap
        let row1 = (0..<10).map { HitRect(x: Double($0) * step, y: 0, width: w, height: h) }
        let inset = step / 2
        let row2 = (0..<9).map { HitRect(x: inset + Double($0) * step, y: h + rowGap, width: w, height: h) }
        let all = row1 + row2
        let point = HitPoint(x: 0, y: h + rowGap + h / 2)
        XCTAssertEqual(KeyHitResolver.nearest(to: point, in: all, maxDistance: KeyHitResolver.defaultMaxDistance), 10)
        XCTAssertNil(KeyHitResolver.nearest(to: point, in: all, maxDistance: rowGap))
    }
}
