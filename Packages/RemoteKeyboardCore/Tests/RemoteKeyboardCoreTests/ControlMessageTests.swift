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

    func testUntrustedStatusRoundTripsAndTrustedKeepsTheOldBytes() throws {
        let untrusted = ControlMessage.status(ReceiverStatus(ready: false, appName: nil, focusEpoch: 1, trusted: false))
        XCTAssertEqual(try ControlCodec.decode(ControlCodec.encode(untrusted)), untrusted)
        let trusted = try ControlCodec.encode(.status(ReceiverStatus(ready: true, appName: "Notes", focusEpoch: 1)))
        XCTAssertFalse(String(decoding: trusted, as: UTF8.self).contains("trusted"), "a trusted status adds nothing to the wire")
        XCTAssertEqual(String(decoding: trusted, as: UTF8.self), #"{"status":{"_0":{"appName":"Notes","focusEpoch":1,"ready":true}}}"#)
    }

    func testStatusFromAnOlderReceiverDecodesAsTrusted() throws {
        let old = try ControlCodec.encode(.status(ReceiverStatus(ready: true, appName: "Notes", focusEpoch: 1)))
        guard case .status(let status) = try ControlCodec.decode(old) else { return XCTFail("not a status") }
        XCTAssertTrue(status.trusted)
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
            .pairAccept(publicKey: Data(repeating: 4, count: 65), host: Fixture.hostIdentity),
            helloMessage(Data(repeating: 1, count: 16)),
            .auth(proof: Data(repeating: 2, count: 32)),
            .authFailed,
            .bye,
            .sealed(Data(repeating: 6, count: 60))
        ]
        for m in messages { XCTAssertEqual(try ControlCodec.decode(ControlCodec.encode(m)), m) }
    }

    func testAuthFailedCarriesNoPayload() throws {
        let text = String(decoding: try ControlCodec.encode(.authFailed), as: UTF8.self)
        XCTAssertEqual(text, #"{"authFailed":{}}"#)
    }

    func testByeCarriesNoPayload() throws {
        XCTAssertEqual(String(decoding: try ControlCodec.encode(.bye), as: UTF8.self), #"{"bye":{}}"#)
    }

    func testAuthMessagesFitOneControlWriteAtTheSmallestMTU() throws {
        // 182 is the smallest maximumUpdateValueLength seen; a control write of the longest new message stays well under 512.
        XCTAssertLessThan(try ControlCodec.encode(.pairAccept(publicKey: Data(repeating: 4, count: 65), host: Fixture.hostIdentity)).count, 512)
    }

    // MARK: Protocol v4 wire shapes (docs/protocol/v4.md §3.2)

    private func text(_ m: ControlMessage) throws -> String { String(decoding: try ControlCodec.encode(m), as: UTF8.self) }

    func testHelloWireShape() throws {
        let nonce = Data((0..<16).map { UInt8(0xA0 + $0) })
        XCTAssertEqual(
            try text(.hello(hostId: Fixture.hostId, hostNonce: nonce)),
            #"{"hello":{"hostId":"AAECAwQFBgcICQoLDA0ODw==","hostNonce":"oKGio6SlpqeoqaqrrK2urw=="}}"#)
    }

    func testPairAcceptWireShape() throws {
        let key = Pairing.publicKeyData(scalarKey(1))
        let wire = try text(.pairAccept(publicKey: key, host: Fixture.hostIdentity))
        // The identity sits beside publicKey, in the order hostId, hostName, platform, publicKey.
        XCTAssertEqual(
            wire,
            #"{"pairAccept":{"hostId":"AAECAwQFBgcICQoLDA0ODw==","hostName":"書房的 Mac","platform":"mac","publicKey":"BGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe\/UfU="}}"#)
        XCTAssertEqual(try ControlCodec.decode(Data(wire.utf8)), .pairAccept(publicKey: key, host: Fixture.hostIdentity))
    }

    func testUnchangedControlMessagesKeepTheirBytes() throws {
        // The examples of docs/protocol/v4.md §3.2, byte for byte.
        let proof = try XCTUnwrap(Data(base64Encoded: "Dz4kCzTD7wPO9kfDy+G3KBavE2Uv6hc2nI0UXuvxs1k="))
        XCTAssertEqual(try text(.auth(proof: proof)), #"{"auth":{"proof":"Dz4kCzTD7wPO9kfDy+G3KBavE2Uv6hc2nI0UXuvxs1k="}}"#)
        XCTAssertEqual(try text(.authFailed), #"{"authFailed":{}}"#)
        XCTAssertEqual(try text(.bye), #"{"bye":{}}"#)
        let id = try XCTUnwrap(UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E"))
        XCTAssertEqual(
            try text(.ack(Ack(eventId: id, result: .posted))),
            #"{"ack":{"_0":{"eventId":"0F8FAD5B-D9CB-469F-A165-70867728950E","result":"posted"}}}"#)
        XCTAssertEqual(
            try text(.status(ReceiverStatus(ready: true, appName: "備忘錄", focusEpoch: 12, pointerGrant: 305_419_896))),
            #"{"status":{"_0":{"appName":"備忘錄","focusEpoch":12,"pointerGrant":305419896,"ready":true}}}"#)
        XCTAssertEqual(
            try text(.status(ReceiverStatus(ready: false, appName: nil, focusEpoch: 1, trusted: false))),
            #"{"status":{"_0":{"focusEpoch":1,"ready":false,"trusted":false}}}"#)
        let sealedExample = #"{"sealed":{"_0":"EBESExQVFhcYGRobjCrkO6K+HLhEllulTkS2B2Zh2P1YORO1JDFOOr+uhQZF5F0f1KINYyq5tRnDvW\/yFi3YGcqUnCKZ9ZCAXpxUnKCxS3bG2TtUDucC8TBOwTbjoJ+eq41UewSxMM+tvwwDv7Nd"}}"#
        let decoded = try ControlCodec.decode(Data(sealedExample.utf8))
        XCTAssertEqual(try text(decoded), sealedExample)
    }

    func testExactlyOneRecognisedMessageNameIsRequired() {
        for json in [#"{}"#, #"{"authFailed":{},"bye":{}}"#, #"{"nope":{}}"#, #"{"bye":{},"hello":{"hostId":"AAECAwQFBgcICQoLDA0ODw==","hostNonce":"oKGio6SlpqeoqaqrrK2urw=="}}"#] {
            XCTAssertThrowsError(try ControlCodec.decode(Data(json.utf8)), json) { XCTAssertEqual($0 as? EventCodecError, .malformed) }
        }
    }

    func testDecoderIgnoresUnknownKeysAndAnyKeyOrder() throws {
        let json = #"{"hello":{"hostNonce":"oKGio6SlpqeoqaqrrK2urw==","extra":1,"hostId":"AAECAwQFBgcICQoLDA0ODw=="},"unknown":{}}"#
        XCTAssertEqual(try ControlCodec.decode(Data(json.utf8)), .hello(hostId: Fixture.hostId, hostNonce: Data((0..<16).map { UInt8(0xA0 + $0) })))
        // The unknown key is ignored only because one recognised name is present.
        XCTAssertEqual(try ControlCodec.decode(Data(#"{"authFailed":{"x":true}}"#.utf8)), .authFailed)
    }

    func testPairAcceptWithMissingOrUnknownFieldsIsMalformed() {
        let ok = #""hostId":"AAECAwQFBgcICQoLDA0ODw==","hostName":"H","platform":"linux","publicKey":"BA==""#
        XCTAssertNoThrow(try ControlCodec.decode(Data(#"{"pairAccept":{\#(ok)}}"#.utf8)))
        for bad in [
            #""hostName":"H","platform":"linux","publicKey":"BA==""#,
            #""hostId":"AAECAwQFBgcICQoLDA0ODw==","platform":"linux","publicKey":"BA==""#,
            #""hostId":"AAECAwQFBgcICQoLDA0ODw==","hostName":"H","publicKey":"BA==""#,
            #""hostId":"AAECAwQFBgcICQoLDA0ODw==","hostName":"H","platform":"linux""#,
            #""hostId":"AAECAwQFBgcICQoLDA0ODw==","hostName":"H","platform":"beos","publicKey":"BA==""#,
            #""hostId":"AAECAwQFBgcICQoLDA0ODw==","hostName":"H","platform":"ios","publicKey":"BA==""#,
            #""hostId":"AAECAwQFBgcICQoLDA0ODw==","hostName":"H","platform":"mac","publicKey":"BA""#,
            #""hostId":"AAECAwQFBgcICQoLDA0ODw==","hostName":7,"platform":"mac","publicKey":"BA==""#
        ] {
            XCTAssertThrowsError(try ControlCodec.decode(Data(#"{"pairAccept":{\#(bad)}}"#.utf8)), bad) {
                XCTAssertEqual($0 as? EventCodecError, .malformed)
            }
        }
    }
}
