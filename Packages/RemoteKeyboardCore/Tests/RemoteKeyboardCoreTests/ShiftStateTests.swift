import XCTest
@testable import RemoteKeyboardCore

final class ShiftStateTests: XCTestCase {
    func testStartsOff() {
        let s = ShiftState()
        XCTAssertEqual(s.mode, .off); XCTAssertFalse(s.isUppercase)
    }

    func testSingleTapTurnsOnceOnAndASecondSlowTapTurnsOff() {
        var s = ShiftState()
        s.tap(at: 10)
        XCTAssertEqual(s.mode, .once); XCTAssertTrue(s.isUppercase)
        s.tap(at: 11)
        XCTAssertEqual(s.mode, .off)
    }

    func testDoubleTapWithinThreeTenthsOfASecondIsCapsLock() {
        var s = ShiftState()
        s.tap(at: 10)
        s.tap(at: 10.2)
        XCTAssertEqual(s.mode, .capsLock); XCTAssertTrue(s.isUppercase)
    }

    func testTheThreeTenthsBoundaryCountsAsADoubleTap() {
        var s = ShiftState()
        s.tap(at: 10)
        s.tap(at: 10.3)
        XCTAssertEqual(s.mode, .capsLock)
    }

    func testJustOverTheBoundaryIsNotADoubleTap() {
        var s = ShiftState()
        s.tap(at: 10)
        s.tap(at: 10.31)
        XCTAssertEqual(s.mode, .off)
    }

    func testTapOnCapsLockTurnsOff() {
        var s = ShiftState()
        s.tap(at: 10); s.tap(at: 10.1)
        s.tap(at: 12)
        XCTAssertEqual(s.mode, .off)
    }

    func testTapOnCapsLockRightAfterTheDoubleTapStillTurnsOff() {
        var s = ShiftState()
        s.tap(at: 10); s.tap(at: 10.1)
        s.tap(at: 10.2)
        XCTAssertEqual(s.mode, .off)
    }

    func testCharacterTypedClearsOnceButNotCapsLock() {
        var s = ShiftState()
        s.tap(at: 1)
        s.characterTyped()
        XCTAssertEqual(s.mode, .off)
        s.tap(at: 5); s.tap(at: 5.1)
        s.characterTyped()
        XCTAssertEqual(s.mode, .capsLock)
    }

    func testCharacterTypedWhileOffStaysOff() {
        var s = ShiftState()
        s.characterTyped()
        XCTAssertEqual(s.mode, .off)
    }

    func testATapAfterATypedLetterStartsFreshEvenInsideTheWindow() {
        var s = ShiftState()
        s.tap(at: 10)
        s.characterTyped()
        s.tap(at: 10.2)
        XCTAssertEqual(s.mode, .once)
    }
}
