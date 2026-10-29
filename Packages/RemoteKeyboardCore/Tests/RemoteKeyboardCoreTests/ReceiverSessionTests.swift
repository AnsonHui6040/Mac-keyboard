import XCTest
@testable import RemoteKeyboardCore

private let t0 = Date(timeIntervalSince1970: 0)

private func armedSession(at now: Date) -> ReceiverSession {
    var s = ReceiverSession()
    _ = s.handle(.editableFocusGained, now: now)
    return s
}

final class ReceiverSessionTests: XCTestCase {
    func testFocusArmsAndSchedulesThirtyMinutes() {
        var s = ReceiverSession()
        XCTAssertEqual(s.handle(.editableFocusGained, now: t0), [.arm, .scheduleTimeout(at: t0.addingTimeInterval(1800))])
        XCTAssertTrue(s.isArmed); XCTAssertEqual(s.deadline, t0.addingTimeInterval(1800))
    }

    func testEventExtendsDeadline() {
        var s = armedSession(at: t0)
        XCTAssertEqual(s.handle(.eventReceived, now: t0.addingTimeInterval(600)), [.scheduleTimeout(at: t0.addingTimeInterval(2400))])
    }

    func testRefocusWhileArmedExtendsWithoutRearm() {
        var s = armedSession(at: t0)
        XCTAssertEqual(s.handle(.editableFocusGained, now: t0.addingTimeInterval(60)), [.scheduleTimeout(at: t0.addingTimeInterval(1860))])
    }

    func testTimerAtDeadlineDisarms() {
        var s = armedSession(at: t0)
        XCTAssertEqual(s.handle(.timerFired, now: t0.addingTimeInterval(1800)), [.disarm])
        XCTAssertFalse(s.isArmed); XCTAssertNil(s.deadline)
    }

    func testStaleTimerIgnoredAfterExtension() {
        var s = armedSession(at: t0); _ = s.handle(.eventReceived, now: t0.addingTimeInterval(600))
        XCTAssertEqual(s.handle(.timerFired, now: t0.addingTimeInterval(1800)), [])
        XCTAssertTrue(s.isArmed)
    }

    func testEventWhileStandbyDoesNotArm() {
        var s = ReceiverSession(); XCTAssertEqual(s.handle(.eventReceived, now: t0), []); XCTAssertFalse(s.isArmed)
    }

    func testManualStopDisarms() {
        var s = armedSession(at: t0); XCTAssertEqual(s.handle(.manualStop, now: t0), [.disarm]); XCTAssertFalse(s.isArmed)
    }

    func testManualStartArms() {
        var s = ReceiverSession()
        XCTAssertEqual(s.handle(.manualStart, now: t0), [.arm, .scheduleTimeout(at: t0.addingTimeInterval(1800))])
    }

    func testManualStopWhileStandbyIsNoOp() {
        var s = ReceiverSession(); XCTAssertEqual(s.handle(.manualStop, now: t0), [])
    }

    func testCustomIdleTimeout() {
        var s = ReceiverSession(idleTimeout: 60)
        XCTAssertEqual(s.handle(.manualStart, now: t0), [.arm, .scheduleTimeout(at: t0.addingTimeInterval(60))])
    }
}
