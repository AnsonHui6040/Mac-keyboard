import XCTest
@testable import RemoteKeyboardCore

final class TrackpadGestureTests: XCTestCase {
    private let ms: UInt64 = 1_000
    private var gesture = TrackpadGesture()

    private func touch(_ id: Int, _ x: Double, _ y: Double, _ t: UInt64) -> TrackpadTouch {
        TrackpadTouch(id: id, x: x, y: y, timeMicros: t * ms)
    }

    func testQuickTapIsAClick() {
        var out = gesture.touchesBegan([touch(1, 100, 100, 0)])
        out += gesture.touchesMoved([touch(1, 103, 102, 40)])
        out += gesture.touchesEnded([touch(1, 103, 102, 120)])
        XCTAssertEqual(out, [.strokeBegan(timeMicros: 0), .click(count: 1, timeMicros: 120 * ms)])
    }

    func testTapAtTwoHundredMillisecondsStillCountsAndLaterDoesNot() {
        _ = gesture.touchesBegan([touch(1, 0, 0, 0)])
        XCTAssertEqual(gesture.touchesEnded([touch(1, 0, 0, 200)]), [.click(count: 1, timeMicros: 200 * ms)])
        _ = gesture.touchesBegan([touch(2, 0, 0, 1_000)])
        XCTAssertEqual(gesture.touchesEnded([touch(2, 0, 0, 1_201)]), [], "a touch held for 201 ms is not a tap")
        XCTAssertTrue(gesture.isIdle)
    }

    func testMovementWithinTheDeadZoneIsHeldBackAndThenCaughtUp() {
        _ = gesture.touchesBegan([touch(1, 100, 100, 0)])
        XCTAssertEqual(gesture.touchesMoved([touch(1, 105, 100, 16)]), [], "5 pt is still inside the 8 pt dead zone")
        let out = gesture.touchesMoved([touch(1, 109, 100, 32)])
        XCTAssertEqual(out, [.move(dx: 9, dy: 0, timeMicros: 32 * ms)], "past 8 pt the finger's whole travel is released at once")
        XCTAssertEqual(gesture.touchesMoved([touch(1, 112, 101, 48)]), [.move(dx: 3, dy: 1, timeMicros: 48 * ms)])
        XCTAssertEqual(gesture.touchesEnded([touch(1, 112, 101, 60)]), [], "a finger that moved never clicks")
        XCTAssertTrue(gesture.isIdle)
    }

    func testMovingFingerThatWasSlowIsNotATapEvenIfShort() {
        _ = gesture.touchesBegan([touch(1, 0, 0, 0)])
        _ = gesture.touchesMoved([touch(1, 20, 0, 50)])
        XCTAssertEqual(gesture.touchesEnded([touch(1, 20, 0, 100)]), [])
    }

    func testLongPressStartsDragAndLiftReleases() {
        _ = gesture.touchesBegan([touch(1, 50, 50, 0)])
        XCTAssertEqual(gesture.tick(nowMicros: 399 * ms), [])
        XCTAssertEqual(gesture.tick(nowMicros: 400 * ms), [.buttonDown(timeMicros: 400 * ms)])
        XCTAssertEqual(gesture.tick(nowMicros: 450 * ms), [], "the press is entered once")
        // After the button is down every move goes out at once, with no dead zone.
        XCTAssertEqual(gesture.touchesMoved([touch(1, 52, 50, 500)]), [.move(dx: 2, dy: 0, timeMicros: 500 * ms)])
        XCTAssertEqual(gesture.touchesMoved([touch(1, 60, 70, 520)]), [.move(dx: 8, dy: 20, timeMicros: 520 * ms)])
        XCTAssertEqual(gesture.touchesEnded([touch(1, 60, 70, 600)]), [.buttonUp(timeMicros: 600 * ms)])
        XCTAssertTrue(gesture.isIdle)
    }

    func testLongPressNeedsTheFingerToStayWithinEightPoints() {
        _ = gesture.touchesBegan([touch(1, 0, 0, 0)])
        _ = gesture.touchesMoved([touch(1, 12, 0, 100)])
        XCTAssertEqual(gesture.tick(nowMicros: 500 * ms), [], "a finger that already moved cannot become a drag")
    }

    func testLongPressWithSmallJitterStillDrags() {
        _ = gesture.touchesBegan([touch(1, 0, 0, 0)])
        _ = gesture.touchesMoved([touch(1, 3, -4, 100)])
        XCTAssertEqual(gesture.tick(nowMicros: 400 * ms), [.buttonDown(timeMicros: 400 * ms)])
    }

    func testTwoFingerMoveScrollsFromBeganToEnded() {
        var out = gesture.touchesBegan([touch(1, 100, 100, 0), touch(2, 140, 100, 5)])
        XCTAssertEqual(out, [], "two fingers down together: no stroke, no click")
        out = gesture.touchesMoved([touch(1, 100, 104, 30), touch(2, 140, 104, 30)])
        XCTAssertEqual(out, [], "4 pt is below the scroll threshold")
        out = gesture.touchesMoved([touch(1, 100, 112, 50)])
        XCTAssertEqual(out, [], "one finger moving 8 pt moves the centre by 4 pt")
        out = gesture.touchesMoved([touch(2, 140, 120, 60)])
        XCTAssertEqual(out, [
            .scrollBegan(timeMicros: 60 * ms),
            .scroll(dx: 0, dy: 16, timeMicros: 60 * ms)
        ])
        out = gesture.touchesMoved([touch(1, 100, 122, 80), touch(2, 140, 130, 80)])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out.reduce(0.0) { sum, o in if case .scroll(_, let dy, _) = o { sum + dy } else { sum } }, 10, accuracy: 1e-9)
        out = gesture.touchesEnded([touch(1, 100, 122, 100)])
        XCTAssertEqual(out, [.scrollEnded(timeMicros: 100 * ms)])
        // The finger that is left does nothing until everyone has lifted.
        XCTAssertEqual(gesture.touchesMoved([touch(2, 140, 200, 120)]), [])
        XCTAssertEqual(gesture.touchesEnded([touch(2, 140, 200, 140)]), [])
        XCTAssertTrue(gesture.isIdle)
    }

    func testTwoFingerTouchThatNeverMovedIsOnlyARightClickWhenQuick() {
        _ = gesture.touchesBegan([touch(1, 0, 0, 0), touch(2, 40, 0, 2)])
        XCTAssertEqual(gesture.touchesEnded([touch(1, 0, 0, 80), touch(2, 40, 0, 82)]), [.rightClick(timeMicros: 82 * ms)])
        XCTAssertTrue(gesture.isIdle)
        _ = gesture.touchesBegan([touch(3, 0, 0, 1_000), touch(4, 40, 0, 1_002)])
        XCTAssertEqual(gesture.touchesEnded([touch(3, 0, 0, 1_500), touch(4, 40, 0, 1_502)]), [])
        XCTAssertTrue(gesture.isIdle)
    }

    func testSecondFingerLandingAfterTheFirstStartedMovingIsIgnored() {
        _ = gesture.touchesBegan([touch(1, 0, 0, 0)])
        _ = gesture.touchesMoved([touch(1, 30, 0, 40)])
        XCTAssertEqual(gesture.touchesBegan([touch(2, 50, 50, 60)]), [])
        XCTAssertEqual(gesture.touchesMoved([touch(2, 90, 90, 70)]), [], "the extra finger is not tracked")
        XCTAssertEqual(gesture.touchesMoved([touch(1, 33, 0, 80)]), [.move(dx: 3, dy: 0, timeMicros: 80 * ms)])
    }

    func testSecondFingerDuringADragIsIgnoredAndTheDragContinues() {
        _ = gesture.touchesBegan([touch(1, 0, 0, 0)])
        _ = gesture.tick(nowMicros: 400 * ms)
        XCTAssertEqual(gesture.touchesBegan([touch(2, 80, 80, 450)]), [])
        XCTAssertEqual(gesture.touchesEnded([touch(2, 80, 80, 460)]), [])
        XCTAssertEqual(gesture.touchesMoved([touch(1, 5, 0, 470)]), [.move(dx: 5, dy: 0, timeMicros: 470 * ms)])
        XCTAssertEqual(gesture.touchesEnded([touch(1, 5, 0, 480)]), [.buttonUp(timeMicros: 480 * ms)])
    }

    func testCancelReleasesADragAndEndsAScroll() {
        _ = gesture.touchesBegan([touch(1, 0, 0, 0)])
        _ = gesture.tick(nowMicros: 400 * ms)
        XCTAssertEqual(gesture.touchesCancelled(atMicros: 450 * ms), [.buttonUp(timeMicros: 450 * ms)])
        XCTAssertTrue(gesture.isIdle)

        _ = gesture.touchesBegan([touch(1, 0, 0, 1_000), touch(2, 40, 0, 1_001)])
        _ = gesture.touchesMoved([touch(1, 0, 20, 1_020), touch(2, 40, 20, 1_020)])
        XCTAssertEqual(gesture.touchesCancelled(atMicros: 1_050 * ms), [.scrollEnded(timeMicros: 1_050 * ms)])
        XCTAssertTrue(gesture.isIdle)

        _ = gesture.touchesBegan([touch(1, 0, 0, 2_000)])
        XCTAssertEqual(gesture.touchesCancelled(atMicros: 2_010 * ms), [], "a pending tap is dropped, not clicked")
        XCTAssertTrue(gesture.isIdle)
    }

    func testResetStateAfterAGestureStartsFresh() {
        _ = gesture.touchesBegan([touch(1, 0, 0, 0)])
        _ = gesture.touchesEnded([touch(1, 0, 0, 50)])
        let out = gesture.touchesBegan([touch(3, 10, 10, 300)])
        XCTAssertEqual(out, [.strokeBegan(timeMicros: 300 * ms)])
        XCTAssertEqual(gesture.touchesEnded([touch(3, 10, 10, 350)]), [.click(count: 1, timeMicros: 350 * ms)])
    }

    // MARK: Double click

    /// A tap at (x, y) from `down` to `up` ms; returns what the lift produced.
    private func tap(_ id: Int, _ x: Double = 100, _ y: Double = 100, down: UInt64, up: UInt64) -> [TrackpadOutput] {
        _ = gesture.touchesBegan([touch(id, x, y, down)])
        return gesture.touchesEnded([touch(id, x, y, up)])
    }

    func testTwoTapsInsideTheLimitsAreClickCountOneThenTwoThenOneAgain() {
        XCTAssertEqual(tap(1, down: 0, up: 50), [.click(count: 1, timeMicros: 50 * ms)])
        XCTAssertEqual(tap(2, 104, 100, down: 150, up: 200), [.click(count: 2, timeMicros: 200 * ms)])
        XCTAssertEqual(tap(3, down: 260, up: 300), [.click(count: 1, timeMicros: 300 * ms)], "no triple click")
    }

    func testSecondTapTooLateTooFarOrAfterAMoveIsCountOne() {
        XCTAssertEqual(tap(1, down: 0, up: 50), [.click(count: 1, timeMicros: 50 * ms)])
        XCTAssertEqual(tap(2, down: 600, up: 640), [.click(count: 1, timeMicros: 640 * ms)], "lift 590 ms after the first lift")

        XCTAssertEqual(tap(3, 200, 200, down: 1_000, up: 1_040), [.click(count: 1, timeMicros: 1_040 * ms)])
        XCTAssertEqual(tap(4, 213, 200, down: 1_100, up: 1_140), [.click(count: 1, timeMicros: 1_140 * ms)], "13 pt away")

        XCTAssertEqual(tap(5, 200, 200, down: 2_000, up: 2_040), [.click(count: 1, timeMicros: 2_040 * ms)])
        _ = gesture.touchesBegan([touch(6, 200, 200, 2_100)])
        _ = gesture.touchesMoved([touch(6, 230, 200, 2_120)])
        _ = gesture.touchesEnded([touch(6, 230, 200, 2_140)])
        XCTAssertEqual(tap(7, 200, 200, down: 2_200, up: 2_240), [.click(count: 1, timeMicros: 2_240 * ms)], "a move forgot the first tap")
    }

    func testTwelvePointsAndFiveHundredMillisecondsStillCount() {
        XCTAssertEqual(tap(1, down: 0, up: 50), [.click(count: 1, timeMicros: 50 * ms)])
        XCTAssertEqual(tap(2, 112, 100, down: 400, up: 550), [.click(count: 2, timeMicros: 550 * ms)])
    }

    func testTwoFingerGestureOrCancelBetweenTapsForgetsTheFirstTap() {
        XCTAssertEqual(tap(1, down: 0, up: 50), [.click(count: 1, timeMicros: 50 * ms)])
        _ = gesture.touchesBegan([touch(2, 100, 100, 100), touch(3, 140, 100, 100)])
        _ = gesture.touchesMoved([touch(2, 100, 130, 120), touch(3, 140, 130, 120)])
        _ = gesture.touchesEnded([touch(2, 100, 130, 140), touch(3, 140, 130, 140)])
        XCTAssertEqual(tap(4, down: 200, up: 240), [.click(count: 1, timeMicros: 240 * ms)])

        _ = gesture.touchesBegan([touch(5, 100, 100, 300)])
        _ = gesture.touchesCancelled(atMicros: 310 * ms)
        XCTAssertEqual(tap(6, down: 350, up: 380), [.click(count: 1, timeMicros: 380 * ms)])
    }

    func testTapThenHoldStillStartsTheDrag() {
        XCTAssertEqual(tap(1, down: 0, up: 50), [.click(count: 1, timeMicros: 50 * ms)])
        _ = gesture.touchesBegan([touch(2, 100, 100, 150)])
        XCTAssertEqual(gesture.tick(nowMicros: 550 * ms), [.buttonDown(timeMicros: 550 * ms)])
        XCTAssertEqual(gesture.touchesEnded([touch(2, 100, 100, 600)]), [.buttonUp(timeMicros: 600 * ms)])
    }

    // MARK: Tap, then press and hold to drag

    func testTapThenPressHeldDragsFromTwoHundredMilliseconds() {
        XCTAssertEqual(tap(1, down: 0, up: 50), [.click(count: 1, timeMicros: 50 * ms)])
        XCTAssertEqual(gesture.touchesBegan([touch(2, 102, 100, 150)]), [.strokeBegan(timeMicros: 150 * ms)])
        XCTAssertEqual(gesture.tick(nowMicros: 349 * ms), [], "not yet 200 ms")
        XCTAssertEqual(gesture.tick(nowMicros: 350 * ms), [.buttonDown(timeMicros: 350 * ms)])
        XCTAssertEqual(gesture.tick(nowMicros: 400 * ms), [], "entered once")
        XCTAssertEqual(gesture.touchesMoved([touch(2, 104, 100, 380)]), [.move(dx: 2, dy: 0, timeMicros: 380 * ms)])
        XCTAssertEqual(gesture.touchesEnded([touch(2, 104, 100, 400)]), [.buttonUp(timeMicros: 400 * ms)])
        XCTAssertTrue(gesture.isIdle)
    }

    func testTapThenPressThatMovesFarStartsTheDragWithTheWholeDistance() {
        XCTAssertEqual(tap(1, down: 0, up: 50), [.click(count: 1, timeMicros: 50 * ms)])
        _ = gesture.touchesBegan([touch(2, 100, 100, 150)])
        XCTAssertEqual(gesture.touchesMoved([touch(2, 105, 100, 200)]), [], "5 pt is inside the dead zone")
        XCTAssertEqual(gesture.touchesMoved([touch(2, 120, 100, 250)]), [
            .buttonDown(timeMicros: 250 * ms),
            .move(dx: 20, dy: 0, timeMicros: 250 * ms)
        ])
        XCTAssertEqual(gesture.touchesMoved([touch(2, 123, 104, 270)]), [.move(dx: 3, dy: 4, timeMicros: 270 * ms)])
        XCTAssertEqual(gesture.touchesEnded([touch(2, 123, 104, 300)]), [.buttonUp(timeMicros: 300 * ms)])
        XCTAssertTrue(gesture.isIdle)
    }

    func testTapThenQuickSecondTapIsStillADoubleClick() {
        XCTAssertEqual(tap(1, down: 0, up: 50), [.click(count: 1, timeMicros: 50 * ms)])
        _ = gesture.touchesBegan([touch(2, 100, 100, 150)])
        XCTAssertEqual(gesture.tick(nowMicros: 199 * ms), [])
        XCTAssertEqual(gesture.touchesEnded([touch(2, 100, 100, 200)]), [.click(count: 2, timeMicros: 200 * ms)])
    }

    func testPressLandingTooLateIsAnOrdinaryTouch() {
        XCTAssertEqual(tap(1, down: 0, up: 50), [.click(count: 1, timeMicros: 50 * ms)])
        _ = gesture.touchesBegan([touch(2, 100, 100, 600)])
        XCTAssertEqual(gesture.tick(nowMicros: 900 * ms), [], "held 300 ms: no drag")
        XCTAssertEqual(gesture.touchesMoved([touch(2, 130, 100, 950)]), [.move(dx: 30, dy: 0, timeMicros: 950 * ms)])
        XCTAssertEqual(gesture.touchesEnded([touch(2, 130, 100, 980)]), [])
    }

    func testPressLandingTooFarAwayIsAnOrdinaryTouch() {
        XCTAssertEqual(tap(1, down: 0, up: 50), [.click(count: 1, timeMicros: 50 * ms)])
        _ = gesture.touchesBegan([touch(2, 120, 100, 150)])
        XCTAssertEqual(gesture.tick(nowMicros: 350 * ms), [], "20 pt away: not a second press")
        XCTAssertEqual(gesture.touchesMoved([touch(2, 150, 100, 400)]), [.move(dx: 30, dy: 0, timeMicros: 400 * ms)])
    }

    func testNextTapAfterATapDragIsCountOne() {
        XCTAssertEqual(tap(1, down: 0, up: 50), [.click(count: 1, timeMicros: 50 * ms)])
        _ = gesture.touchesBegan([touch(2, 100, 100, 150)])
        _ = gesture.tick(nowMicros: 350 * ms)
        XCTAssertEqual(gesture.touchesEnded([touch(2, 100, 100, 400)]), [.buttonUp(timeMicros: 400 * ms)])
        XCTAssertEqual(tap(3, down: 450, up: 480), [.click(count: 1, timeMicros: 480 * ms)])

        // Same after a drag that began with a move.
        XCTAssertEqual(tap(4, down: 2_000, up: 2_040), [.click(count: 1, timeMicros: 2_040 * ms)])
        _ = gesture.touchesBegan([touch(5, 100, 100, 2_100)])
        _ = gesture.touchesMoved([touch(5, 130, 100, 2_120)])
        _ = gesture.touchesEnded([touch(5, 130, 100, 2_150)])
        XCTAssertEqual(tap(6, 130, 100, down: 2_200, up: 2_230), [.click(count: 1, timeMicros: 2_230 * ms)])
    }

    func testCancelDuringATapDragReleasesTheButton() {
        XCTAssertEqual(tap(1, down: 0, up: 50), [.click(count: 1, timeMicros: 50 * ms)])
        _ = gesture.touchesBegan([touch(2, 100, 100, 150)])
        _ = gesture.tick(nowMicros: 350 * ms)
        XCTAssertEqual(gesture.touchesCancelled(atMicros: 400 * ms), [.buttonUp(timeMicros: 400 * ms)])
        XCTAssertTrue(gesture.isIdle)
        XCTAssertEqual(tap(3, down: 450, up: 480), [.click(count: 1, timeMicros: 480 * ms)])
    }

    func testPlainLongPressStillDragsAtFourHundredMillisecondsWithoutAPrecedingTap() {
        _ = gesture.touchesBegan([touch(1, 50, 50, 0)])
        XCTAssertEqual(gesture.tick(nowMicros: 200 * ms), [], "no tap before: the 200 ms rule does not apply")
        XCTAssertEqual(gesture.tick(nowMicros: 400 * ms), [.buttonDown(timeMicros: 400 * ms)])
    }

    func testSecondFingerDuringTheSecondPressIsATwoFingerGesture() {
        XCTAssertEqual(tap(1, down: 0, up: 50), [.click(count: 1, timeMicros: 50 * ms)])
        _ = gesture.touchesBegan([touch(2, 100, 100, 150)])
        _ = gesture.touchesBegan([touch(3, 140, 100, 170)])
        XCTAssertEqual(gesture.tick(nowMicros: 400 * ms), [], "a pair never becomes a drag")
        XCTAssertEqual(gesture.touchesEnded([touch(2, 100, 100, 250), touch(3, 140, 100, 250)]), [.rightClick(timeMicros: 250 * ms)])
    }

    // MARK: Right click

    func testTwoFingerTapTogetherIsARightClickWhenTheLastFingerLifts() {
        _ = gesture.touchesBegan([touch(1, 100, 100, 0), touch(2, 140, 100, 0)])
        XCTAssertEqual(gesture.touchesEnded([touch(1, 101, 100, 80)]), [])
        XCTAssertEqual(gesture.touchesEnded([touch(2, 141, 101, 120)]), [.rightClick(timeMicros: 120 * ms)])
        XCTAssertTrue(gesture.isIdle)
    }

    func testTwoFingerTapThroughPendingCountsFromTheFirstFinger() {
        _ = gesture.touchesBegan([touch(1, 100, 100, 0)])
        _ = gesture.touchesBegan([touch(2, 140, 100, 40)])
        XCTAssertEqual(gesture.touchesEnded([touch(1, 100, 100, 120), touch(2, 140, 100, 120)]), [.rightClick(timeMicros: 120 * ms)])
    }

    func testTwoFingerTapAtThreeHundredMillisecondsCountsAndLaterDoesNot() {
        _ = gesture.touchesBegan([touch(1, 100, 100, 0), touch(2, 140, 100, 0)])
        XCTAssertEqual(gesture.touchesEnded([touch(1, 100, 100, 300), touch(2, 140, 100, 300)]), [.rightClick(timeMicros: 300 * ms)])
        _ = gesture.touchesBegan([touch(3, 100, 100, 1_000), touch(4, 140, 100, 1_000)])
        XCTAssertEqual(gesture.touchesEnded([touch(3, 100, 100, 1_301), touch(4, 140, 100, 1_301)]), [], "too slow")
    }

    func testTwoFingersThatTravelledTooFarAreNotARightClick() {
        // Both move the same way by 10 pt: the centre stays under 8 pt only if they move opposite ways, so spread apart.
        _ = gesture.touchesBegan([touch(1, 100, 100, 0), touch(2, 140, 100, 0)])
        XCTAssertEqual(gesture.touchesMoved([touch(1, 90, 100, 20), touch(2, 150, 100, 20)]), [], "centre has not moved")
        _ = gesture.touchesMoved([touch(1, 87, 100, 30)])
        XCTAssertEqual(gesture.touchesEnded([touch(1, 87, 100, 80), touch(2, 150, 100, 80)]), [], "finger 1 travelled 13 pt")
    }

    func testTwoFingersThatScrolledAreNotARightClick() {
        _ = gesture.touchesBegan([touch(1, 100, 100, 0), touch(2, 140, 100, 0)])
        _ = gesture.touchesMoved([touch(1, 100, 125, 20), touch(2, 140, 125, 20)])
        let out = gesture.touchesEnded([touch(1, 100, 125, 80), touch(2, 140, 125, 80)])
        XCTAssertEqual(out, [.scrollEnded(timeMicros: 80 * ms)])
    }

    func testThreeFingersAndCancelAreNotARightClick() {
        _ = gesture.touchesBegan([touch(1, 100, 100, 0), touch(2, 140, 100, 0)])
        _ = gesture.touchesBegan([touch(3, 180, 100, 20)])
        XCTAssertEqual(gesture.touchesEnded([touch(1, 100, 100, 80), touch(2, 140, 100, 80), touch(3, 180, 100, 80)]), [])
        XCTAssertTrue(gesture.isIdle)

        _ = gesture.touchesBegan([touch(4, 100, 100, 1_000), touch(5, 140, 100, 1_000)])
        XCTAssertEqual(gesture.touchesCancelled(atMicros: 1_050 * ms), [])
        XCTAssertTrue(gesture.isIdle)
        XCTAssertEqual(gesture.touchesEnded([touch(4, 100, 100, 1_060), touch(5, 140, 100, 1_060)]), [])
    }
}
