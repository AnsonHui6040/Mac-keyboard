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
        let data = try EventCodec.encode(makeEvent(version: 4), maxBytes: 400)
        XCTAssertThrowsError(try EventCodec.decode(data)) { error in
            XCTAssertEqual(error as? EventCodecError, .unsupportedVersion(4))
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
        XCTAssertThrowsError(try EventCodec.decode(Data("{\"protocolVersion\":3}".utf8))) {
            XCTAssertEqual($0 as? EventCodecError, .malformed)
        }
    }

    // MARK: Protocol v3 (T09)

    func testProtocolVersionIsThree() { XCTAssertEqual(KeyboardEvent.currentVersion, 3) }

    func testPeripheralMessageRoundTripsEveryCase() throws {
        let key = Data(repeating: 4, count: 65)
        let messages: [PeripheralMessage] = [
            .event(makeEvent()),
            .pairOffer(commitment: Data(repeating: 5, count: 32)),
            .pairReveal(publicKey: key),
            .helloReply(phoneNonce: Data(repeating: 1, count: 16), proof: Data(repeating: 2, count: 32)),
            .sealed(Data(repeating: 3, count: 80))
        ]
        for message in messages {
            XCTAssertEqual(try PeripheralCodec.decode(PeripheralCodec.encode(message)), message)
        }
    }

    func testEveryPeripheralMessageCarriesTheVersionAtTheTopLevel() throws {
        let messages: [PeripheralMessage] = [
            .pairOffer(commitment: Data([1])), .pairReveal(publicKey: Data([4])), .helloReply(phoneNonce: Data([1]), proof: Data([2])), .sealed(Data([3]))
        ]
        for message in messages {
            let object = try JSONSerialization.jsonObject(with: PeripheralCodec.encode(message)) as? [String: Any]
            XCTAssertEqual(object?["protocolVersion"] as? Int, 3)
            XCTAssertNotNil(object?["type"] as? String)
        }
    }

    func testOldVersionPairOfferIsRejectedAsUnsupported() {
        let old = Data(#"{"protocolVersion":2,"type":"pairOffer","commitment":"AQ=="}"#.utf8)
        XCTAssertThrowsError(try PeripheralCodec.decode(old)) { XCTAssertEqual($0 as? EventCodecError, .unsupportedVersion(2)) }
    }

    func testUnknownTypeAndMissingFieldsAreMalformed() {
        for json in [#"{"protocolVersion":3,"type":"nope"}"#, #"{"protocolVersion":3,"type":"sealed"}"#,
                     #"{"protocolVersion":3,"type":"helloReply","phoneNonce":"AQ=="}"#, #"{"protocolVersion":3}"#] {
            XCTAssertThrowsError(try PeripheralCodec.decode(Data(json.utf8)), json) { XCTAssertEqual($0 as? EventCodecError, .malformed) }
        }
    }

    func testSealedLargestTextEventFitsOneMessage() throws {
        let key = SymmetricKey(data: Data(repeating: 5, count: 32))
        let crypto = SessionCrypto(
            pairKey: key, macNonce: Data(repeating: 1, count: 16), phoneNonce: Data(repeating: 2, count: 16), direction: .phoneToMac)
        let event = makeEvent(kind: .text(String(repeating: "香", count: 200)))
        let sealed = try crypto.seal(PeripheralCodec.encode(.event(event)))
        let wire = try PeripheralCodec.encode(.sealed(sealed))
        XCTAssertLessThan(wire.count, FrameCodec.maxMessageBytes)
        guard case .sealed(let back) = try PeripheralCodec.decode(wire) else { return XCTFail() }
        XCTAssertEqual(try PeripheralCodec.decode(crypto.open(back)), .event(event))
    }
}
