import XCTest
@testable import RemoteKeyboardCore

final class ControlMessageTests: XCTestCase {
    func testControlStatusRoundTrip() throws {
        let m = ControlMessage.status(ReceiverStatus(ready: true, appName: "TextEdit", focusEpoch: 3))
        XCTAssertEqual(try ControlCodec.decode(ControlCodec.encode(m)), m)
    }

    func testStatusWithoutAppNameRoundTrips() throws {
        let m = ControlMessage.status(ReceiverStatus(ready: false, appName: nil, focusEpoch: 0))
        XCTAssertEqual(try ControlCodec.decode(ControlCodec.encode(m)), m)
    }

    func testAckRoundTripForEveryCode() throws {
        let codes: [AckCode] = [.posted, .notAuthorized, .noFocus, .staleFocus, .switchFailed, .malformed, .compositionActive,
                                .injectFailed, .pong, .outOfOrder]
        for code in codes {
            let m = ControlMessage.ack(Ack(eventId: UUID(), result: code))
            XCTAssertEqual(try ControlCodec.decode(ControlCodec.encode(m)), m)
        }
    }

    func testCompositionActiveRawValue() { XCTAssertEqual(AckCode.compositionActive.rawValue, "compositionActive") }

    func testMalformedControlRejected() {
        XCTAssertThrowsError(try ControlCodec.decode(Data("nope".utf8))) { XCTAssertEqual($0 as? EventCodecError, .malformed) }
    }
}
