import XCTest
@testable import RemoteKeyboardCore

final class EventSenderTests: XCTestCase {
    func testSenderNumbersSeqFromOneAndCarriesEpoch() {
        let id = UUID(); var s = EventSender(sessionId: id)
        let a = s.make(.text("a"), focusEpoch: 7), b = s.make(.backspace, focusEpoch: 7)
        XCTAssertEqual([a.seq, b.seq], [1, 2])
        XCTAssertEqual([a.focusEpoch, b.focusEpoch], [7, 7])
        XCTAssertEqual(a.sessionId, id)
        XCTAssertEqual(a.protocolVersion, KeyboardEvent.currentVersion)
        XCTAssertNotEqual(a.eventId, b.eventId)
        let ping = s.make(.ping(shownAtMs: 1, connectedAtMs: 2), focusEpoch: 7)
        XCTAssertNil(ping.focusEpoch, "a probe never carries a focus epoch")
        XCTAssertEqual(ping.seq, 3)
    }

    func testProbeIsNumberedButNeverCountedAsPending() {
        var s = EventSender(sessionId: UUID())
        let probe = s.make(.probe, focusEpoch: 7)
        XCTAssertNil(probe.focusEpoch)
        XCTAssertEqual(probe.seq, 1)
        XCTAssertEqual(s.pendingCount, 0, "a probe never shows up as an unconfirmed key")
        XCTAssertEqual(s.linkLost(), 0)
    }

    func testMissingEpochStaysMissing() {
        var s = EventSender(sessionId: UUID())
        XCTAssertNil(s.make(.returnKey, focusEpoch: nil).focusEpoch)
    }

    func testLinkLostReportsPendingAndNeverResends() {
        var s = EventSender(sessionId: UUID())
        let a = s.make(.text("a"), focusEpoch: 1); _ = s.make(.text("b"), focusEpoch: 1); _ = s.make(.text("c"), focusEpoch: 1)
        XCTAssertEqual(s.pendingCount, 3)
        s.acknowledged(Ack(eventId: a.eventId, result: .posted))
        XCTAssertEqual(s.pendingCount, 2)
        XCTAssertEqual(s.linkLost(), 2)
        XCTAssertEqual(s.pendingCount, 0)
        XCTAssertEqual(s.linkLost(), 0, "reporting twice does not double count")
    }

    func testAnyAckResultConfirmsDelivery() {
        var s = EventSender(sessionId: UUID())
        let a = s.make(.text("a"), focusEpoch: 1)
        s.acknowledged(Ack(eventId: a.eventId, result: .staleFocus))
        XCTAssertEqual(s.pendingCount, 0, "a refusal is still an answer from the Receiver")
    }

    func testUnknownAndRepeatedAcksChangeNothing() {
        var s = EventSender(sessionId: UUID())
        let a = s.make(.text("a"), focusEpoch: 1)
        s.acknowledged(Ack(eventId: Ack.unknownEventId, result: .malformed))
        s.acknowledged(Ack(eventId: UUID(), result: .posted))
        XCTAssertEqual(s.pendingCount, 1)
        s.acknowledged(Ack(eventId: a.eventId, result: .posted))
        s.acknowledged(Ack(eventId: a.eventId, result: .posted))
        XCTAssertEqual(s.pendingCount, 0)
    }

    func testPingsAreNotCountedAsUnconfirmedKeys() {
        var s = EventSender(sessionId: UUID())
        _ = s.make(.ping(shownAtMs: 1, connectedAtMs: 2), focusEpoch: nil)
        XCTAssertEqual(s.pendingCount, 0)
        XCTAssertEqual(s.linkLost(), 0)
    }

    func testUnsentEventIsForgottenAndItsSeqReused() {
        var s = EventSender(sessionId: UUID())
        let a = s.make(.text("a"), focusEpoch: 1)
        s.unsent(a)
        XCTAssertEqual(s.pendingCount, 0)
        XCTAssertEqual(s.make(.text("b"), focusEpoch: 1).seq, 1, "an event that never left does not leave a gap")
    }

    func testUnsentOlderEventOnlyLeavesPending() {
        var s = EventSender(sessionId: UUID())
        let a = s.make(.text("a"), focusEpoch: 1); _ = s.make(.text("b"), focusEpoch: 1)
        s.unsent(a)
        XCTAssertEqual(s.pendingCount, 1)
        XCTAssertEqual(s.make(.text("c"), focusEpoch: 1).seq, 3)
    }

    func testNewSenderStartsANewSession() {
        var first = EventSender(sessionId: UUID()), second = EventSender(sessionId: UUID())
        XCTAssertNotEqual(first.make(.backspace, focusEpoch: 1).sessionId, second.make(.backspace, focusEpoch: 1).sessionId)
    }
}
