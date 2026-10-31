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
        // The default touch correction (3 pt up) moves the middle of the 12 pt gap down: see the touchYOffset tests.
        XCTAssertEqual(KeyHitResolver.nearest(to: HitPoint(x: 10, y: 43), in: keys, maxDistance: rowGap), 0)
        XCTAssertEqual(KeyHitResolver.nearest(to: HitPoint(x: 10, y: 51), in: keys, maxDistance: rowGap), 2)
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

    // MARK: Touch correction (touchYOffset)

    func testDefaultTouchYOffsetIsThreePoints() {
        XCTAssertEqual(KeyHitResolver.defaultTouchYOffset, 3)
    }

    /// The gap is 12 pt: y 40 to 52. A touch d pt below the upper row is corrected to d - 3: up to 9 pt it is still
    /// the upper row (9 is an exact tie, which takes the earlier key), from 10 pt on it is the lower row.
    func testRowGapMiddleMovesDownByTheTouchOffset() {
        func key(atY y: Double) -> Int? {
            KeyHitResolver.nearest(to: HitPoint(x: 10, y: y), in: keys, maxDistance: KeyHitResolver.defaultMaxDistance)
        }
        XCTAssertEqual(key(atY: 40 + 6), 0, "the geometric middle now belongs to the upper row")
        XCTAssertEqual(key(atY: 40 + 9), 0)
        XCTAssertEqual(key(atY: 40 + 10), 2)
        XCTAssertEqual(key(atY: 40 + 11), 2)
    }

    func testZeroOffsetKeepsThePlainNearestKey() {
        func key(atY y: Double) -> Int? {
            KeyHitResolver.nearest(
                to: HitPoint(x: 10, y: y), in: keys, maxDistance: KeyHitResolver.defaultMaxDistance, touchYOffset: 0)
        }
        XCTAssertEqual(key(atY: 40 + 5), 0)
        XCTAssertEqual(key(atY: 40 + 7), 2)
    }

    /// A touch inside a key is that key, however close another key is: no correction there.
    func testPointInsideAKeyIsNeverCorrected() {
        // 1 pt inside the lower row.
        XCTAssertEqual(
            KeyHitResolver.nearest(to: HitPoint(x: 10, y: 53), in: keys, maxDistance: KeyHitResolver.defaultMaxDistance), 2)
        // Inside the upper key, 1 pt above its bottom edge.
        XCTAssertEqual(
            KeyHitResolver.nearest(to: HitPoint(x: 10, y: 39), in: keys, maxDistance: KeyHitResolver.defaultMaxDistance), 0)
        // Even with a large offset the key under the finger wins.
        XCTAssertEqual(
            KeyHitResolver.nearest(
                to: HitPoint(x: 10, y: 53), in: keys, maxDistance: KeyHitResolver.defaultMaxDistance, touchYOffset: 20), 2)
    }

    func testHorizontalGapIsNotAffectedByTheOffset() {
        XCTAssertEqual(KeyHitResolver.nearest(to: HitPoint(x: 41, y: 20), in: keys, maxDistance: rowGap), 0)
        XCTAssertEqual(KeyHitResolver.nearest(to: HitPoint(x: 45, y: 20), in: keys, maxDistance: rowGap), 1)
        XCTAssertEqual(KeyHitResolver.nearest(to: HitPoint(x: 43, y: 20), in: keys, maxDistance: rowGap), 0)
    }

    /// The corrected point picks the key, but the key must still be within reach of the real touch.
    func testCorrectedChoiceMustStillBeWithinReachOfTheRealTouch() {
        // One key at y 0...40. A touch 5 pt below it is 2 pt away after correction, but the real distance is 5.
        let one = [HitRect(x: 0, y: 0, width: 40, height: 40)]
        XCTAssertNil(KeyHitResolver.nearest(to: HitPoint(x: 20, y: 45), in: one, maxDistance: 4))
        XCTAssertEqual(KeyHitResolver.nearest(to: HitPoint(x: 20, y: 45), in: one, maxDistance: 5), 0)
    }

    /// Above the first row the correction would move the touch away from it; the key is still found by reach.
    func testTouchAboveTheFirstRowStillReachesIt() {
        let top = [HitRect(x: 0, y: 4, width: 40, height: 40)]
        XCTAssertEqual(KeyHitResolver.nearest(to: HitPoint(x: 20, y: 0), in: top, maxDistance: 42), 0)
    }
}
