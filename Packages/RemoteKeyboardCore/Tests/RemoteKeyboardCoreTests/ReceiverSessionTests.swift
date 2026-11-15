import XCTest
@testable import RemoteKeyboardCore

final class ReceiverSessionTests: XCTestCase {
    func testStartsPaused() {
        XCTAssertFalse(ReceiverSession().isArmed)
    }

    func testStartArms() {
        var s = ReceiverSession()
        XCTAssertEqual(s.handle(.start), [.arm])
        XCTAssertTrue(s.isArmed)
    }

    func testStartWhileArmedIsNoOp() {
        var s = ReceiverSession(); _ = s.handle(.start)
        XCTAssertEqual(s.handle(.start), [])
        XCTAssertTrue(s.isArmed)
    }

    func testStopDisarms() {
        var s = ReceiverSession(); _ = s.handle(.start)
        XCTAssertEqual(s.handle(.stop), [.disarm])
        XCTAssertFalse(s.isArmed)
    }

    func testStopWhilePausedIsNoOp() {
        var s = ReceiverSession()
        XCTAssertEqual(s.handle(.stop), [])
        XCTAssertFalse(s.isArmed)
    }
}
