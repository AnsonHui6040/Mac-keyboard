import XCTest
@testable import RemoteKeyboardCore

final class ReplayWindowTests: XCTestCase {
    func testCounterZeroNeverAccepted() {
        XCTAssertFalse(ReplayWindow().check(0))
    }

    func testFirstCounterAccepted() {
        XCTAssertTrue(ReplayWindow().check(1))
    }

    func testSeenCounterRejectedAfterCommit() {
        var window = ReplayWindow()
        window.commit(5)
        XCTAssertFalse(window.check(5))
        XCTAssertTrue(window.check(6))
    }

    func testCheckAloneDoesNotMoveTheWindow() {
        var window = ReplayWindow()
        XCTAssertTrue(window.check(5))
        XCTAssertTrue(window.check(5), "nothing was committed")
    }

    func testOlderCounterInsideTheWindowAcceptedOnce() {
        var window = ReplayWindow()
        window.commit(100)
        XCTAssertTrue(window.check(36))
        window.commit(36)
        XCTAssertFalse(window.check(36))
        XCTAssertEqual(window.verdict(36), .replayed)
    }

    func testCounterSixtyFiveBelowIsTooOld() {
        var window = ReplayWindow()
        window.commit(100)
        XCTAssertEqual(window.verdict(35), .tooOld)
        XCTAssertEqual(window.verdict(36), .accept)
    }

    func testBigJumpForgetsEverythingBelow() {
        var window = ReplayWindow()
        window.commit(10)
        window.commit(1000)
        XCTAssertEqual(window.verdict(10), .tooOld)
        XCTAssertEqual(window.verdict(999), .accept)
    }

    func testJumpBySixtyFourKeepsTheOldMaximumRemembered() {
        var window = ReplayWindow()
        window.commit(10)
        window.commit(74)
        XCTAssertEqual(window.verdict(10), .replayed)
        window.commit(75)
        XCTAssertEqual(window.verdict(10), .tooOld)
    }

    func testCommitOfAnOlderCounterKeepsTheMaximum() {
        var window = ReplayWindow()
        window.commit(50)
        window.commit(40)
        XCTAssertEqual(window.verdict(50), .replayed)
        XCTAssertEqual(window.verdict(40), .replayed)
        XCTAssertEqual(window.verdict(41), .accept)
        XCTAssertEqual(window.verdict(51), .accept)
    }

    func testMaximumCounterValue() {
        var window = ReplayWindow()
        window.commit(UInt64.max - 1)
        XCTAssertTrue(window.check(UInt64.max))
        window.commit(UInt64.max)
        XCTAssertFalse(window.check(UInt64.max))
        XCTAssertFalse(window.check(UInt64.max - 1))
    }
}
