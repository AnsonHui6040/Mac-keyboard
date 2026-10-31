import XCTest
@testable import RemoteKeyboardCore

final class PointerSenderTests: XCTestCase {
    private let ms: UInt64 = 1_000

    /// Hands every packet that is due at `now` to the "radio" and returns them.
    private func drain(_ sender: PointerSender, at now: UInt64) -> [PointerPayload] {
        var packets: [PointerPayload] = []
        while let payload = sender.peek(nowMicros: now) {
            packets.append(payload)
            sender.handedOff(nowMicros: now)
        }
        return packets
    }

    func testQuantizationKeepsTheRemainderForTheNextPacket() {
        let sender = PointerSender()
        sender.strokeBegan(atMicros: 0)
        var sentSixteenths = 0
        var now: UInt64 = 0
        // 100 samples of 0.03 pt: 3 pt in all, 48 sixteenths, none of which is a whole sixteenth on its own.
        for _ in 0..<100 {
            now += 20 * ms
            sender.addMove(dx: 0.03, dy: 0, atMicros: now)
            for packet in drain(sender, at: now) where packet.opcode == .move { sentSixteenths += Int(packet.dx) }
        }
        XCTAssertEqual(sentSixteenths, 48)
        XCTAssertNil(sender.peek(nowMicros: now + 100 * ms), "nothing is left but a remainder under one sixteenth")
    }

    func testMoveCarriesQuantizedDeltaAndTimeSpan() throws {
        let sender = PointerSender()
        sender.strokeBegan(atMicros: 1_000_000)
        sender.addMove(dx: 1.5, dy: -0.25, atMicros: 1_008_000)
        sender.addMove(dx: 0.5, dy: -0.25, atMicros: 1_016_000)
        let packet = try XCTUnwrap(sender.peek(nowMicros: 1_016_000))
        XCTAssertEqual(packet.opcode, .move)
        XCTAssertEqual(packet.dx, 32)
        XCTAssertEqual(packet.dy, -8)
        XCTAssertEqual(packet.dt, 160, "16 ms from the touch down to the last sample, in tenths of a millisecond")
        XCTAssertEqual(packet.buttons & 0x03, 0)
        XCTAssertEqual(packet.status, 0)
    }

    func testMovesAreSpacedByTheMoveInterval() {
        let sender = PointerSender()
        sender.strokeBegan(atMicros: 0)
        sender.addMove(dx: 5, dy: 0, atMicros: 1 * ms)
        XCTAssertEqual(drain(sender, at: 1 * ms).count, 1, "the first move after rest goes at once")
        sender.addMove(dx: 5, dy: 0, atMicros: 5 * ms)
        XCTAssertEqual(drain(sender, at: 5 * ms).count, 0, "too soon after the last move")
        XCTAssertEqual(drain(sender, at: 1 * ms + PointerSender.moveIntervalMicros).count, 1)
    }

    func testBackpressureProducesExactlyOneMoveWithEverythingAccumulated() throws {
        let sender = PointerSender()
        sender.strokeBegan(atMicros: 0)
        sender.addMove(dx: 4, dy: 0, atMicros: 1 * ms)
        XCTAssertNotNil(sender.peek(nowMicros: 1 * ms))
        sender.refused()
        XCTAssertTrue(sender.isBlocked)
        for step in 2...10 {
            sender.addMove(dx: 1, dy: 0, atMicros: UInt64(step) * 20 * ms)
            XCTAssertNil(sender.peek(nowMicros: UInt64(step) * 20 * ms), "no packet is formed while the radio is full")
        }
        sender.radioReady()
        let now = 500 * ms
        let packets = drain(sender, at: now)
        XCTAssertEqual(packets.count, 1)
        let move = try XCTUnwrap(packets.first)
        XCTAssertEqual(move.dx, 13 * 16, "the refused 4 pt and the 9 pt that came after")
        XCTAssertEqual(move.status & 0x01, 0x01, "flagged as accumulated during a block")
    }

    func testClickIsPrecededByTheMoveThatCameBeforeIt() {
        let sender = PointerSender()
        sender.strokeBegan(atMicros: 0)
        sender.addMove(dx: 10, dy: 0, atMicros: 2 * ms)
        sender.click(atMicros: 3 * ms)
        sender.addMove(dx: 4, dy: 0, atMicros: 4 * ms)
        let packets = drain(sender, at: 4 * ms)
        XCTAssertEqual(packets.map(\.opcode), [.move, .click])
        XCTAssertEqual(packets[0].dx, 160)
        XCTAssertEqual(packets[1].arg, PointerPayload.clickArg(count: 1))
        XCTAssertEqual(packets[1].dx, 0)
        XCTAssertEqual(packets[1].dy, 0)
        // The movement after the click waits for the pacing and then follows.
        let later = drain(sender, at: 4 * ms + PointerSender.moveIntervalMicros)
        XCTAssertEqual(later.map(\.opcode), [.move])
        XCTAssertEqual(later[0].dx, 64)
    }

    func testButtonStateBarrierKeepsOldStateOnTheMoveBeforeAndNewStateAfter() {
        let sender = PointerSender()
        sender.strokeBegan(atMicros: 0)
        sender.addMove(dx: 2, dy: 0, atMicros: 1 * ms)
        sender.setLeftButton(true, atMicros: 2 * ms)
        sender.addMove(dx: 3, dy: 0, atMicros: 3 * ms)
        sender.setLeftButton(false, atMicros: 40 * ms)
        let packets = drain(sender, at: 40 * ms)
        XCTAssertEqual(packets.map(\.opcode), [.move, .buttonState, .move, .buttonState])
        XCTAssertEqual(packets.map { $0.buttons & 0x03 }, [0, 1, 1, 0])
        XCTAssertEqual(packets.map(\.buttonSeq), [0, 1, 1, 2])
        XCTAssertEqual(packets.map(\.dx), [32, 0, 48, 0])
    }

    func testButtonStateRepeatsAreNotProduced() {
        let sender = PointerSender()
        sender.setLeftButton(false, atMicros: 1 * ms)
        XCTAssertEqual(drain(sender, at: 1 * ms).count, 0, "releasing what is not pressed is nothing")
        sender.setLeftButton(true, atMicros: 2 * ms)
        sender.setLeftButton(true, atMicros: 3 * ms)
        XCTAssertEqual(drain(sender, at: 3 * ms).map(\.opcode), [.buttonState])
    }

    func testHeartbeatEveryHundredMillisecondsOnlyWhileHeld() {
        let sender = PointerSender()
        XCTAssertNil(sender.peek(nowMicros: 1_000 * ms), "no heartbeat without a button")
        sender.setLeftButton(true, atMicros: 1_000 * ms)
        XCTAssertEqual(drain(sender, at: 1_000 * ms).map(\.opcode), [.buttonState])
        XCTAssertEqual(drain(sender, at: 1_050 * ms).count, 0)
        XCTAssertEqual(drain(sender, at: 1_100 * ms).map(\.opcode), [.heartbeat])
        XCTAssertEqual(drain(sender, at: 1_150 * ms).count, 0)
        let second = drain(sender, at: 1_200 * ms)
        XCTAssertEqual(second.map(\.opcode), [.heartbeat])
        XCTAssertEqual(second[0].buttons & 0x03, 1)
        XCTAssertEqual(second[0].buttonSeq, 1)
        sender.setLeftButton(false, atMicros: 1_210 * ms)
        XCTAssertEqual(drain(sender, at: 1_210 * ms).map(\.opcode), [.buttonState])
        XCTAssertEqual(drain(sender, at: 2_000 * ms).count, 0, "released: the heartbeat stops")
    }

    func testAHeartbeatNeverWaitsInALine() {
        let sender = PointerSender()
        sender.setLeftButton(true, atMicros: 0)
        _ = drain(sender, at: 0)
        // Nobody ticked for a full second: one heartbeat is due, not ten.
        XCTAssertEqual(drain(sender, at: 1_000 * ms).map(\.opcode), [.heartbeat])
    }

    func testScrollBeganChangedEnded() {
        let sender = PointerSender()
        sender.scrollBegan(atMicros: 0)
        sender.addScroll(dx: 0, dy: 10, atMicros: 1 * ms)
        sender.addScroll(dx: 0, dy: 6, atMicros: 5 * ms)
        var packets = drain(sender, at: 5 * ms)
        XCTAssertEqual(packets.map(\.opcode), [.scroll])
        XCTAssertEqual(packets[0].scrollPhase, .began)
        XCTAssertEqual(packets[0].dy, 256)
        sender.addScroll(dx: 2, dy: 1, atMicros: 40 * ms)
        packets = drain(sender, at: 40 * ms)
        XCTAssertEqual(packets.map(\.opcode), [.scroll])
        XCTAssertEqual(packets[0].scrollPhase, .changed)
        XCTAssertEqual(packets[0].dx, 32)
        sender.addScroll(dx: 0, dy: 3, atMicros: 41 * ms)
        sender.scrollEnded(atMicros: 42 * ms)
        packets = drain(sender, at: 42 * ms)
        XCTAssertEqual(packets.map(\.opcode), [.scroll, .scroll])
        XCTAssertEqual(packets.map(\.scrollPhase), [.changed, .ended])
        XCTAssertEqual(packets[0].dy, 48, "the scroll that came before the end is not lost")
        XCTAssertEqual(packets[1].dy, 0)
        XCTAssertEqual(drain(sender, at: 500 * ms).count, 0)
    }

    func testScrollEndedWithoutAnyScrollStillSendsBeganFirst() {
        let sender = PointerSender()
        sender.scrollBegan(atMicros: 0)
        sender.scrollEnded(atMicros: 1 * ms)
        XCTAssertEqual(drain(sender, at: 1 * ms).map(\.scrollPhase), [.began, .ended])
    }

    func testReleaseAllFlushesMovesThenReleasesButtonAndEndsScroll() {
        let sender = PointerSender()
        sender.strokeBegan(atMicros: 0)
        sender.setLeftButton(true, atMicros: 1 * ms)
        sender.addMove(dx: 3, dy: 0, atMicros: 2 * ms)
        sender.releaseAll(atMicros: 3 * ms)
        let packets = drain(sender, at: 3 * ms)
        XCTAssertEqual(packets.map(\.opcode), [.buttonState, .move, .buttonState])
        XCTAssertEqual(packets.last?.buttons.nonzeroLeft, false)
        XCTAssertFalse(sender.isLeftDown)

        let scroller = PointerSender()
        scroller.scrollBegan(atMicros: 0)
        scroller.addScroll(dx: 0, dy: 4, atMicros: 1 * ms)
        scroller.releaseAll(atMicros: 2 * ms)
        XCTAssertEqual(drain(scroller, at: 2 * ms).map(\.scrollPhase), [.began, .ended])
    }

    func testButtonSeqWrapsAtSixteenBits() {
        let sender = PointerSender(startingButtonSeq: 65_535)
        sender.setLeftButton(true, atMicros: 1 * ms)
        let packets = drain(sender, at: 1 * ms)
        XCTAssertEqual(packets.first?.buttonSeq, 0)
    }

    func testOverflowingDisplacementIsSplitIntoSeveralMovesWithTheSameTotal() {
        let sender = PointerSender()
        sender.strokeBegan(atMicros: 0)
        sender.addMove(dx: 3_000, dy: -3_000, atMicros: 1 * ms)
        sender.click(atMicros: 2 * ms)
        let packets = drain(sender, at: 2 * ms)
        XCTAssertEqual(packets.last?.opcode, .click)
        let moves = packets.filter { $0.opcode == .move }
        XCTAssertGreaterThan(moves.count, 1)
        XCTAssertEqual(moves.reduce(0) { $0 + Int($1.dx) }, 48_000)
        XCTAssertEqual(moves.reduce(0) { $0 + Int($1.dy) }, -48_000)
    }
}

private extension UInt8 {
    var nonzeroLeft: Bool { self & 0x01 != 0 }
}
