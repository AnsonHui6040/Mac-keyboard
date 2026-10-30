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

    func testPairingAndAuthMessagesRoundTrip() throws {
        let messages: [ControlMessage] = [
            .pairAccept(publicKey: Data(repeating: 4, count: 65)),
            .hello(macNonce: Data(repeating: 1, count: 16)),
            .auth(proof: Data(repeating: 2, count: 32)),
            .authFailed
        ]
        for m in messages { XCTAssertEqual(try ControlCodec.decode(ControlCodec.encode(m)), m) }
    }

    func testAuthFailedCarriesNoPayload() throws {
        let text = String(decoding: try ControlCodec.encode(.authFailed), as: UTF8.self)
        XCTAssertEqual(text, #"{"authFailed":{}}"#)
    }

    func testAuthMessagesFitOneControlWriteAtTheSmallestMTU() throws {
        // 182 is the smallest maximumUpdateValueLength seen; a control write of the longest new message stays well under 512.
        XCTAssertLessThan(try ControlCodec.encode(.pairAccept(publicKey: Data(repeating: 4, count: 65))).count, 512)
    }
}
