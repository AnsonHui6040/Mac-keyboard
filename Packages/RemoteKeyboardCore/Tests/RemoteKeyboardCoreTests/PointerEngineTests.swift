import XCTest
@testable import RemoteKeyboardCore

final class PointerEngineTests: XCTestCase {
    private let ms: UInt64 = 1_000
    private var engine = PointerEngine()

    private func move(
        dx: Int16 = 0, dy: Int16 = 0, dt: UInt16 = 160, buttons: UInt8 = 0, seq: UInt16 = 0
    ) -> PointerPayload {
        PointerPayload(opcode: .move, buttons: buttons, dx: dx, dy: dy, dt: dt, buttonSeq: seq)
    }

    private func heartbeat(buttons: UInt8, seq: UInt16) -> PointerPayload {
        PointerPayload(opcode: .heartbeat, buttons: buttons, dx: 0, dy: 0, dt: 0, buttonSeq: seq)
    }

    private func buttonState(buttons: UInt8, seq: UInt16) -> PointerPayload {
        PointerPayload(opcode: .buttonState, buttons: buttons, dx: 0, dy: 0, dt: 0, buttonSeq: seq)
    }

    func testMoveIsScaledByTheAccelerationCurve() {
        let actions = engine.handle(move(dx: 256, dy: -128, dt: 160), nowMicros: 0)
        let speed = (16.0 * 16.0 + 8.0 * 8.0).squareRoot() / 0.016
        let gain = PointerAcceleration.gain(speed: speed)
        guard case .move(let dx, let dy, let dragging)? = actions.first, actions.count == 1 else { return XCTFail("\(actions)") }
        XCTAssertEqual(dx, 16 * gain, accuracy: 1e-9)
        XCTAssertEqual(dy, -8 * gain, accuracy: 1e-9)
        XCTAssertFalse(dragging)
    }

    func testMoveWithZeroDisplacementDoesNothing() {
        XCTAssertEqual(engine.handle(move(), nowMicros: 0), [])
    }

    func testMoveWhileTheButtonIsHeldIsADrag() {
        XCTAssertEqual(engine.handle(buttonState(buttons: 1, seq: 1), nowMicros: 0), [.leftButton(down: true)])
        guard case .move(_, _, let dragging)? = engine.handle(move(dx: 16, buttons: 1, seq: 1), nowMicros: 10 * ms).first
        else { return XCTFail("no move") }
        XCTAssertTrue(dragging)
    }

    func testAMoveCarryingANewerButtonStateAppliesItBeforeMoving() {
        let actions = engine.handle(move(dx: 16, buttons: 1, seq: 4), nowMicros: 0)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions.first, .leftButton(down: true))
        guard case .move(_, _, let dragging)? = actions.last else { return XCTFail("no move") }
        XCTAssertTrue(dragging)
    }

    func testOlderButtonSeqNeverOverwritesANewerState() {
        _ = engine.handle(buttonState(buttons: 1, seq: 5), nowMicros: 0)
        // A stale release (seq 4) arrives late, with a larger counter in the envelope; it must not release.
        XCTAssertEqual(engine.handle(buttonState(buttons: 0, seq: 4), nowMicros: 5 * ms), [])
        XCTAssertTrue(engine.leftDown)
        // The same seq is not newer either.
        XCTAssertEqual(engine.handle(buttonState(buttons: 0, seq: 5), nowMicros: 6 * ms), [])
        XCTAssertTrue(engine.leftDown)
        XCTAssertEqual(engine.handle(buttonState(buttons: 0, seq: 6), nowMicros: 7 * ms), [.leftButton(down: false)])
        XCTAssertFalse(engine.leftDown)
    }

    func testSequenceComparisonWrapsAround() {
        _ = engine.handle(buttonState(buttons: 1, seq: 65_535), nowMicros: 0)
        XCTAssertEqual(engine.handle(buttonState(buttons: 0, seq: 0), nowMicros: 1 * ms), [.leftButton(down: false)], "0 follows 65,535")
        XCTAssertEqual(engine.handle(buttonState(buttons: 1, seq: 65_535), nowMicros: 2 * ms), [], "65,535 is now older")
    }

    func testLostButtonStateIsCorrectedByTheNextPacket() {
        _ = engine.handle(buttonState(buttons: 1, seq: 1), nowMicros: 0)
        // The release (seq 2) never arrived; the next heartbeat or move already carries it.
        XCTAssertEqual(engine.handle(heartbeat(buttons: 0, seq: 2), nowMicros: 100 * ms), [.leftButton(down: false)])
    }

    func testWatchdogReleasesAfter350MillisecondsOfSilence() {
        _ = engine.handle(buttonState(buttons: 1, seq: 1), nowMicros: 1_000 * ms)
        XCTAssertTrue(engine.needsWatchdog)
        XCTAssertEqual(engine.watchdog(nowMicros: 1_349 * ms), [])
        XCTAssertEqual(engine.watchdog(nowMicros: 1_350 * ms), [.leftButton(down: false)])
        XCTAssertFalse(engine.leftDown)
        XCTAssertFalse(engine.needsWatchdog)
        XCTAssertEqual(engine.watchdog(nowMicros: 2_000 * ms), [], "released once")
    }

    func testAnyValidPacketKeepsTheWatchdogQuiet() {
        _ = engine.handle(buttonState(buttons: 1, seq: 1), nowMicros: 0)
        _ = engine.handle(heartbeat(buttons: 1, seq: 1), nowMicros: 300 * ms)
        XCTAssertEqual(engine.watchdog(nowMicros: 600 * ms), [])
        _ = engine.handle(move(dx: 16, buttons: 1, seq: 1), nowMicros: 640 * ms)
        XCTAssertEqual(engine.watchdog(nowMicros: 900 * ms), [])
        XCTAssertEqual(engine.watchdog(nowMicros: 990 * ms), [.leftButton(down: false)])
    }

    func testLateHeartbeatWithTheSameButtonSeqDoesNotPressAgainAfterAWatchdogRelease() {
        _ = engine.handle(buttonState(buttons: 1, seq: 7), nowMicros: 0)
        _ = engine.watchdog(nowMicros: 400 * ms)
        XCTAssertEqual(engine.handle(heartbeat(buttons: 1, seq: 7), nowMicros: 410 * ms), [])
        XCTAssertFalse(engine.leftDown)
        XCTAssertEqual(engine.handle(move(dx: 16, buttons: 1, seq: 7), nowMicros: 420 * ms).count, 1, "only the move itself")
        // A newer press by the user is accepted.
        XCTAssertEqual(engine.handle(buttonState(buttons: 1, seq: 8), nowMicros: 900 * ms), [.leftButton(down: true)])
    }

    func testClickAtTheCurrentPosition() {
        let click = PointerPayload(opcode: .click, buttons: 0, dx: 0, dy: 0, dt: 0, arg: PointerPayload.clickArg(count: 1), buttonSeq: 0)
        XCTAssertEqual(engine.handle(click, nowMicros: 0), [.click(count: 1)])
    }

    func testClickIsIgnoredWhileTheButtonIsHeld() {
        _ = engine.handle(buttonState(buttons: 1, seq: 1), nowMicros: 0)
        let click = PointerPayload(opcode: .click, buttons: 1, dx: 0, dy: 0, dt: 0, arg: PointerPayload.clickArg(count: 1), buttonSeq: 1)
        XCTAssertEqual(engine.handle(click, nowMicros: 1 * ms), [])
    }

    func testDoubleClickCarriesItsCount() {
        let click = PointerPayload(opcode: .click, buttons: 0, dx: 0, dy: 0, dt: 0, arg: PointerPayload.clickArg(count: 2), buttonSeq: 0)
        XCTAssertEqual(engine.handle(click, nowMicros: 0), [.click(count: 2)])
    }

    func testRightButtonClick() {
        let click = PointerPayload(opcode: .click, buttons: 0, dx: 0, dy: 0, dt: 0, arg: PointerPayload.clickArg(button: 1, count: 1), buttonSeq: 0)
        XCTAssertEqual(engine.handle(click, nowMicros: 0), [.rightClick])
    }

    func testRightClickIsIgnoredWhileTheButtonIsHeld() {
        _ = engine.handle(buttonState(buttons: 1, seq: 1), nowMicros: 0)
        let click = PointerPayload(opcode: .click, buttons: 1, dx: 0, dy: 0, dt: 0, arg: PointerPayload.clickArg(button: 1, count: 1), buttonSeq: 1)
        XCTAssertEqual(engine.handle(click, nowMicros: 1 * ms), [])
    }

    func testScrollPhasesAndUnitScale() {
        func scroll(_ phase: PointerPayload.ScrollPhase, dy: Int16) -> PointerPayload {
            PointerPayload(opcode: .scroll, buttons: 0, dx: 0, dy: dy, dt: 160, arg: phase.rawValue, buttonSeq: 0)
        }
        XCTAssertEqual(engine.handle(scroll(.began, dy: 160), nowMicros: 0), [.scroll(dx: 0, dy: 10, phase: .began)])
        XCTAssertEqual(engine.handle(scroll(.changed, dy: -32), nowMicros: 16 * ms), [.scroll(dx: 0, dy: -2, phase: .changed)])
        XCTAssertTrue(engine.isScrolling)
        XCTAssertEqual(engine.handle(scroll(.ended, dy: 0), nowMicros: 32 * ms), [.scroll(dx: 0, dy: 0, phase: .ended)])
        XCTAssertFalse(engine.isScrolling)
        XCTAssertEqual(engine.handle(scroll(.ended, dy: 0), nowMicros: 33 * ms), [], "an end without a scroll is nothing")
    }

    func testChangedWithoutBeganIsTreatedAsBegan() {
        let changed = PointerPayload(opcode: .scroll, buttons: 0, dx: 16, dy: 0, dt: 160, arg: 0, buttonSeq: 0)
        XCTAssertEqual(engine.handle(changed, nowMicros: 0), [.scroll(dx: 1, dy: 0, phase: .began)])
    }

    func testScrollWatchdogEndsAfter150Milliseconds() {
        let began = PointerPayload(opcode: .scroll, buttons: 0, dx: 0, dy: 16, dt: 160, arg: 1, buttonSeq: 0)
        _ = engine.handle(began, nowMicros: 0)
        XCTAssertTrue(engine.needsWatchdog)
        XCTAssertEqual(engine.watchdog(nowMicros: 149 * ms), [])
        XCTAssertEqual(engine.watchdog(nowMicros: 150 * ms), [.scroll(dx: 0, dy: 0, phase: .ended)])
        XCTAssertFalse(engine.isScrolling)
    }

    func testResetReleasesEverythingAtOnce() {
        _ = engine.handle(buttonState(buttons: 1, seq: 1), nowMicros: 0)
        let began = PointerPayload(opcode: .scroll, buttons: 1, dx: 0, dy: 16, dt: 160, arg: 1, buttonSeq: 1)
        _ = engine.handle(began, nowMicros: 1 * ms)
        let actions = engine.reset()
        XCTAssertEqual(actions, [.leftButton(down: false), .scroll(dx: 0, dy: 0, phase: .ended)])
        XCTAssertFalse(engine.leftDown)
        XCTAssertFalse(engine.isScrolling)
        XCTAssertEqual(engine.reset(), [], "nothing left to release")
        // A new session starts from nothing: seq 1 is accepted again.
        XCTAssertEqual(engine.handle(buttonState(buttons: 1, seq: 1), nowMicros: 2 * ms), [.leftButton(down: true)])
    }
}
