import CryptoKit
import XCTest
@testable import RemoteKeyboardCore

final class EventCodecTests: XCTestCase {
    private func makeEvent(version: Int = KeyboardEvent.currentVersion, kind: EventKind = .text("A"), epoch: UInt64? = 7) -> KeyboardEvent {
        KeyboardEvent(protocolVersion: version, eventId: UUID(), sessionId: UUID(), seq: 1, focusEpoch: epoch, kind: kind)
    }

    func testTextARoundTrip() throws {
        let e = KeyboardEvent(protocolVersion: KeyboardEvent.currentVersion, eventId: UUID(), sessionId: UUID(), seq: 1, focusEpoch: 7, kind: .text("A"))
        XCTAssertEqual(try EventCodec.decode(EventCodec.encode(e, maxBytes: 182)), e)
    }

    func testEveryKindRoundTripsIncludingNilEpoch() throws {
        let kinds: [EventKind] = [.text("香港"), .backspace, .returnKey, .ping(shownAtMs: 10, connectedAtMs: 20), .probe]
        for kind in kinds {
            let e = makeEvent(kind: kind, epoch: nil)
            XCTAssertEqual(try EventCodec.decode(EventCodec.encode(e, maxBytes: 400)), e)
        }
    }

    func testPingWithDaysOfUptimeFitsTheSmallestNotifyPayload() throws {
        // 182 is the smallest maximumUpdateValueLength seen; 9-digit milliseconds is eleven days of process uptime.
        let e = KeyboardEvent(
            protocolVersion: KeyboardEvent.currentVersion, eventId: UUID(), sessionId: UUID(), seq: 1, focusEpoch: nil,
            kind: .ping(shownAtMs: 999_999_000, connectedAtMs: 999_999_999))
        let data = try EventCodec.encode(e, maxBytes: 182)
        XCTAssertLessThanOrEqual(data.count, 182)
        XCTAssertEqual(try EventCodec.decode(data), e)
    }

    func testOnlyProbesGoWithoutAFocusEpoch() {
        XCTAssertFalse(EventKind.ping(shownAtMs: 1, connectedAtMs: 2).carriesFocusEpoch)
        XCTAssertFalse(EventKind.probe.carriesFocusEpoch, "the liveness probe is not typed text either")
        for kind in [EventKind.text("A"), .backspace, .returnKey] { XCTAssertTrue(kind.carriesFocusEpoch) }
    }

    func testEncodingIsDeterministicSortedKeys() throws {
        let e = makeEvent()
        XCTAssertEqual(try EventCodec.encode(e, maxBytes: 400), try EventCodec.encode(e, maxBytes: 400))
    }

    func testRejectsUnknownVersion() throws {
        let data = try EventCodec.encode(makeEvent(version: 5), maxBytes: 400)
        XCTAssertThrowsError(try EventCodec.decode(data)) { error in
            XCTAssertEqual(error as? EventCodecError, .unsupportedVersion(5))
        }
    }

    func testRejectsTooLarge() {
        let e = makeEvent(kind: .text(String(repeating: "香", count: 100)))
        XCTAssertThrowsError(try EventCodec.encode(e, maxBytes: 182)) { error in
            guard case .tooLarge(let size)? = error as? EventCodecError else { return XCTFail("\(error)") }
            XCTAssertGreaterThan(size, 182)
        }
    }

    func testMalformedDataRejected() {
        XCTAssertThrowsError(try EventCodec.decode(Data("{".utf8))) { XCTAssertEqual($0 as? EventCodecError, .malformed) }
        XCTAssertThrowsError(try EventCodec.decode(Data())) { XCTAssertEqual($0 as? EventCodecError, .malformed) }
        XCTAssertThrowsError(try EventCodec.decode(Data("{\"protocolVersion\":4}".utf8))) {
            XCTAssertEqual($0 as? EventCodecError, .malformed)
        }
    }

    // MARK: Protocol v4

    func testProtocolVersionIsFour() { XCTAssertEqual(KeyboardEvent.currentVersion, 4) }

    func testPeripheralMessageRoundTripsEveryCase() throws {
        let key = Data(repeating: 4, count: 65)
        let messages: [PeripheralMessage] = [
            .event(makeEvent()),
            .pairOffer(commitment: Data(repeating: 5, count: 32)),
            .pairReveal(publicKey: key, phone: Fixture.phoneIdentity),
            .helloReply(phoneNonce: Data(repeating: 1, count: 16), proof: Data(repeating: 2, count: 32)),
            .notSelected,
            .sealed(Data(repeating: 3, count: 80))
        ]
        for message in messages {
            XCTAssertEqual(try PeripheralCodec.decode(PeripheralCodec.encode(message)), message)
        }
    }

    func testEveryPeripheralMessageCarriesTheVersionAtTheTopLevel() throws {
        let messages: [PeripheralMessage] = [
            .pairOffer(commitment: Data([1])), .pairReveal(publicKey: Data([4]), phone: Fixture.phoneIdentity),
            .helloReply(phoneNonce: Data([1]), proof: Data([2])), .notSelected, .sealed(Data([3]))
        ]
        for message in messages {
            let object = try JSONSerialization.jsonObject(with: PeripheralCodec.encode(message)) as? [String: Any]
            XCTAssertEqual(object?["protocolVersion"] as? Int, 4)
            XCTAssertNotNil(object?["type"] as? String)
        }
    }

    func testOldVersionPairOfferIsRejectedAsUnsupported() {
        let old = Data(#"{"protocolVersion":2,"type":"pairOffer","commitment":"AQ=="}"#.utf8)
        XCTAssertThrowsError(try PeripheralCodec.decode(old)) { XCTAssertEqual($0 as? EventCodecError, .unsupportedVersion(2)) }
    }

    func testUnknownTypeAndMissingFieldsAreMalformed() {
        for json in [#"{"protocolVersion":4,"type":"nope"}"#, #"{"protocolVersion":4,"type":"sealed"}"#,
                     #"{"protocolVersion":4,"type":"helloReply","phoneNonce":"AQ=="}"#, #"{"protocolVersion":4}"#,
                     #"{"protocolVersion":4,"type":"pairReveal","publicKey":"BA==","phoneId":"EBESExQVFhcYGRobHB0eHw==","phoneName":"P"}"#,
                     #"{"protocolVersion":4,"type":"pairReveal","publicKey":"BA==","phoneId":"EBESExQVFhcYGRobHB0eHw==","phoneName":"P","phonePlatform":"beos"}"#] {
            XCTAssertThrowsError(try PeripheralCodec.decode(Data(json.utf8)), json) { XCTAssertEqual($0 as? EventCodecError, .malformed) }
        }
    }

    func testSealedLargestTextEventFitsOneMessage() throws {
        let key = SymmetricKey(data: Data(repeating: 5, count: 32))
        let crypto = SessionCrypto(
            pairKey: key, hostNonce: Data(repeating: 1, count: 16), phoneNonce: Data(repeating: 2, count: 16), direction: .phoneToMac)
        let event = makeEvent(kind: .text(String(repeating: "香", count: 200)))
        let sealed = try crypto.seal(PeripheralCodec.encode(.event(event)))
        let wire = try PeripheralCodec.encode(.sealed(sealed))
        XCTAssertLessThan(wire.count, FrameCodec.maxMessageBytes)
        guard case .sealed(let back) = try PeripheralCodec.decode(wire) else { return XCTFail() }
        XCTAssertEqual(try PeripheralCodec.decode(crypto.open(back)), .event(event))
    }

    func testVersion3MessageIsUnsupportedVersion() {
        // A v3 phone: the version is read first, so none of these is merely "malformed".
        for json in [#"{"commitment":"AQ==","protocolVersion":3,"type":"pairOffer"}"#,
                     #"{"protocolVersion":3,"publicKey":"BA==","type":"pairReveal"}"#,
                     #"{"payload":"AQ==","protocolVersion":3,"type":"sealed"}"#,
                     #"{"protocolVersion":3,"type":"unknownYet"}"#] {
            XCTAssertThrowsError(try PeripheralCodec.decode(Data(json.utf8)), json) {
                XCTAssertEqual($0 as? EventCodecError, .unsupportedVersion(3))
            }
        }
        XCTAssertThrowsError(try EventCodec.decode(Data(#"{"protocolVersion":3}"#.utf8))) {
            XCTAssertEqual($0 as? EventCodecError, .unsupportedVersion(3))
        }
    }

    func testPairRevealWireShape() throws {
        let key = Pairing.publicKeyData(scalarKey(2))
        let wire = try PeripheralCodec.encode(.pairReveal(publicKey: key, phone: Fixture.phoneIdentity))
        XCTAssertEqual(
            String(decoding: wire, as: UTF8.self),
            #"{"phoneId":"EBESExQVFhcYGRobHB0eHw==","phoneName":"Anson 的 iPhone","phonePlatform":"ios","protocolVersion":4,"publicKey":"BHzyexiNA09+ilI4AwS1GsPAiWnid\/IbNaYLSPxHZpl4B3dVENuO0EApPZrGn3Qw27p9reY86YIpngS3nSJ4c9E=","type":"pairReveal"}"#)
        XCTAssertEqual(try PeripheralCodec.decode(wire), .pairReveal(publicKey: key, phone: Fixture.phoneIdentity))
    }

    func testNotSelectedWireShape() throws {
        let wire = try PeripheralCodec.encode(.notSelected)
        XCTAssertEqual(String(decoding: wire, as: UTF8.self), #"{"protocolVersion":4,"type":"notSelected"}"#)
        XCTAssertEqual(try PeripheralCodec.decode(wire), .notSelected)
    }

    func testPairOfferAndHelloReplyKeepTheirV4Bytes() throws {
        let commitment = try XCTUnwrap(Data(base64Encoded: "qmn6tkRDxcEgxyJGaYUqyjpBwuFUXfRocPOuhb6QpGc="))
        XCTAssertEqual(
            String(decoding: try PeripheralCodec.encode(.pairOffer(commitment: commitment)), as: UTF8.self),
            #"{"commitment":"qmn6tkRDxcEgxyJGaYUqyjpBwuFUXfRocPOuhb6QpGc=","protocolVersion":4,"type":"pairOffer"}"#)
        let nonce = Data((0..<16).map { UInt8(0xB0 + $0) })
        let proof = try XCTUnwrap(Data(base64Encoded: "gSjeDFQ5PKWiJFofBUa6nHIfEWptkf3UzlwjqVieT9A="))
        XCTAssertEqual(
            String(decoding: try PeripheralCodec.encode(.helloReply(phoneNonce: nonce, proof: proof)), as: UTF8.self),
            #"{"phoneNonce":"sLGys7S1tre4ubq7vL2+vw==","proof":"gSjeDFQ5PKWiJFofBUa6nHIfEWptkf3UzlwjqVieT9A=","protocolVersion":4,"type":"helloReply"}"#)
    }

    func testEventWireShapeMatchesTheProtocolExample() throws {
        let event = KeyboardEvent(
            protocolVersion: 4, eventId: try XCTUnwrap(UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E")),
            sessionId: try XCTUnwrap(UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")), seq: 1, focusEpoch: 7, kind: .text("A"))
        XCTAssertEqual(
            String(decoding: try PeripheralCodec.encode(.event(event)), as: UTF8.self),
            #"{"eventId":"0F8FAD5B-D9CB-469F-A165-70867728950E","focusEpoch":7,"kind":{"text":{"_0":"A"}},"protocolVersion":4,"seq":1,"sessionId":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","type":"event"}"#)
    }
}
