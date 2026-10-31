import XCTest
@testable import RemoteKeyboardCore

final class KeyRolloverTrackerTests: XCTestCase {
    func testSingleTapSendsOnTouchUp() {
        var tracker = KeyRolloverTracker()
        XCTAssertEqual(tracker.touchDown(1), [])
        XCTAssertTrue(tracker.touchUpInside(1))
    }

    func testSecondKeyDownSendsTheFirstAtOnce() {
        var tracker = KeyRolloverTracker()
        XCTAssertEqual(tracker.touchDown(1), [])
        XCTAssertEqual(tracker.touchDown(2), [1])
    }

    func testReleaseOfAnAlreadySentKeyDoesNotSendAgain() {
        var tracker = KeyRolloverTracker()
        _ = tracker.touchDown(1)
        _ = tracker.touchDown(2)
        XCTAssertFalse(tracker.touchUpInside(1))
        XCTAssertTrue(tracker.touchUpInside(2))
    }

    func testReleaseOrderDoesNotChangeSendOrder() {
        // Down 1, down 2, release 2, release 1: 1 went out at the second touch down, 2 at its own release.
        var tracker = KeyRolloverTracker()
        var sent: [Int] = []
        sent += tracker.touchDown(1)
        sent += tracker.touchDown(2)
        if tracker.touchUpInside(2) { sent.append(2) }
        if tracker.touchUpInside(1) { sent.append(1) }
        XCTAssertEqual(sent, [1, 2])
    }

    func testThreeOverlappingKeysSendInPressOrder() {
        var tracker = KeyRolloverTracker()
        var sent: [Int] = []
        sent += tracker.touchDown(1)
        sent += tracker.touchDown(2)
        sent += tracker.touchDown(3)
        for key in [1, 2, 3] where tracker.touchUpInside(key) { sent.append(key) }
        XCTAssertEqual(sent, [1, 2, 3])
    }

    func testTwentyFastKeysWithOverlapSendEachOnceInOrder() {
        // A fast two-handed burst: every key goes down before the previous one is released.
        var tracker = KeyRolloverTracker()
        var sent: [Int] = []
        for key in 1...20 {
            sent += tracker.touchDown(key)
            if key > 1, tracker.touchUpInside(key - 1) { sent.append(key - 1) }
        }
        if tracker.touchUpInside(20) { sent.append(20) }
        XCTAssertEqual(sent, Array(1...20))
    }

    func testCancelledKeySendsNothingAndIsNotFlushedLater() {
        var tracker = KeyRolloverTracker()
        _ = tracker.touchDown(1)
        tracker.cancel(1)
        XCTAssertEqual(tracker.touchDown(2), [])
        XCTAssertFalse(tracker.touchUpInside(1))
        XCTAssertTrue(tracker.touchUpInside(2))
    }

    func testSameKeyPressedAgainAfterReleaseSendsAgain() {
        var tracker = KeyRolloverTracker()
        _ = tracker.touchDown(1)
        XCTAssertTrue(tracker.touchUpInside(1))
        XCTAssertEqual(tracker.touchDown(1), [])
        XCTAssertTrue(tracker.touchUpInside(1))
    }

    func testTouchDownOfTheSameKeyTwiceDoesNotFlushIt() {
        var tracker = KeyRolloverTracker()
        _ = tracker.touchDown(1)
        XCTAssertEqual(tracker.touchDown(1), [])
        XCTAssertTrue(tracker.touchUpInside(1))
        XCTAssertFalse(tracker.touchUpInside(1))
    }

    func testReleaseWithoutTouchDownSendsNothing() {
        var tracker = KeyRolloverTracker()
        XCTAssertFalse(tracker.touchUpInside(9))
    }

    func testResetForgetsPendingKeys() {
        var tracker = KeyRolloverTracker()
        _ = tracker.touchDown(1)
        tracker.reset()
        XCTAssertEqual(tracker.touchDown(2), [])
        XCTAssertFalse(tracker.touchUpInside(1))
    }
}
