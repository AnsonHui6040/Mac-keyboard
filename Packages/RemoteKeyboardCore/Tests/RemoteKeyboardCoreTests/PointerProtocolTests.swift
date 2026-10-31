import XCTest
@testable import RemoteKeyboardCore

final class PointerProtocolTests: XCTestCase {
    func testStatusWithoutPointerGrantKeepsTheOldBytes() throws {
        let status = ReceiverStatus(ready: true, appName: "Notes", focusEpoch: 1)
        XCTAssertNil(status.pointerGrant)
        let bytes = try ControlCodec.encode(.status(status))
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self), #"{"status":{"_0":{"appName":"Notes","focusEpoch":1,"ready":true}}}"#)
    }

    func testStatusWithPointerGrantRoundTrips() throws {
        let status = ReceiverStatus(ready: true, appName: nil, focusEpoch: 2, pointerGrant: 4_000_000_001)
        let bytes = try ControlCodec.encode(.status(status))
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains(#""pointerGrant":4000000001"#))
        XCTAssertEqual(try ControlCodec.decode(bytes), .status(status))
    }

    func testOldStatusDecodesWithoutGrant() throws {
        let old = Data(#"{"status":{"_0":{"appName":"Notes","focusEpoch":1,"ready":true}}}"#.utf8)
        guard case .status(let status) = try ControlCodec.decode(old) else { return XCTFail("not a status") }
        XCTAssertNil(status.pointerGrant)
    }

    func testPointerOpenAndCloseEventsRoundTrip() throws {
        for kind in [EventKind.pointerOpen(grant: 77), .pointerClose] {
            let event = KeyboardEvent(
                protocolVersion: KeyboardEvent.currentVersion, eventId: UUID(), sessionId: UUID(), seq: 3, focusEpoch: nil, kind: kind)
            let data = try EventCodec.encode(event, maxBytes: 4_096)
            XCTAssertEqual(try EventCodec.decode(data), event)
        }
    }

    func testPointerEventsCarryNoFocusEpochAndAreNotPendingKeys() {
        XCTAssertFalse(EventKind.pointerOpen(grant: 1).carriesFocusEpoch)
        XCTAssertFalse(EventKind.pointerClose.carriesFocusEpoch)
        var sender = EventSender(sessionId: UUID())
        let open = sender.make(.pointerOpen(grant: 5), focusEpoch: 9)
        _ = sender.make(.pointerClose, focusEpoch: 9)
        XCTAssertNil(open.focusEpoch)
        XCTAssertEqual(sender.pendingCount, 0, "a pointer switch is not an unconfirmed typed key")
    }

    func testPointerChannelStateReadsTheGrantAndAck() {
        XCTAssertEqual(StatusLine.pointerDeniedText, "Mac 未允許觸控板控制")
    }
}
