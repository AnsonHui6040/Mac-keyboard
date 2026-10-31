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
        XCTAssertEqual(out, [.strokeBegan(timeMicros: 0), .click(timeMicros: 120 * ms)])
    }

    func testTapAtTwoHundredMillisecondsStillCountsAndLaterDoesNot() {
        _ = gesture.touchesBegan([touch(1, 0, 0, 0)])
        XCTAssertEqual(gesture.touchesEnded([touch(1, 0, 0, 200)]), [.click(timeMicros: 200 * ms)])
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

    func testTwoFingerTouchThatNeverMovedProducesNothing() {
        _ = gesture.touchesBegan([touch(1, 0, 0, 0), touch(2, 40, 0, 2)])
        XCTAssertEqual(gesture.touchesEnded([touch(1, 0, 0, 80), touch(2, 40, 0, 82)]), [])
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
        XCTAssertEqual(gesture.touchesEnded([touch(3, 10, 10, 350)]), [.click(timeMicros: 350 * ms)])
    }
}
