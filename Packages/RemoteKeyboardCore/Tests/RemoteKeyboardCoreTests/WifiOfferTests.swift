import XCTest
@testable import RemoteKeyboardCore

/// `pointerOpen` with the optional `wifi` field (docs/protocol/v4.md §3.4, spec W2, §5.1).
final class WifiOfferTests: XCTestCase {
    private let eventId = UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E")!
    private let sessionId = UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!

    private func event(_ kind: EventKind) -> KeyboardEvent {
        KeyboardEvent(protocolVersion: 4, eventId: eventId, sessionId: sessionId, seq: 4, focusEpoch: nil, kind: kind)
    }

    private func wire(_ kindJson: String) -> Data {
        Data(
            """
            {"eventId":"0F8FAD5B-D9CB-469F-A165-70867728950E","kind":\(kindJson),"protocolVersion":4,"seq":4,"sessionId":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","type":"event"}
            """.utf8)
    }

    private func decodedKind(_ kindJson: String) throws -> EventKind {
        guard case .event(let event) = try PeripheralCodec.decode(wire(kindJson)) else { throw EventCodecError.malformed }
        return event.kind
    }

    private func kindBytes(_ kind: EventKind) throws -> String {
        let bytes = try PeripheralCodec.encode(.event(event(kind)))
        let text = String(decoding: bytes, as: UTF8.self)
        guard let start = text.range(of: #""kind":"#), let end = text.range(of: #","protocolVersion""#) else { return text }
        return String(text[start.upperBound..<end.lowerBound])
    }

    // MARK: Canonical bytes

    func testPointerOpenWithWifiEncodesToTheSpecExample() throws {
        let offer = try XCTUnwrap(WifiOffer(addrs: ["192.168.1.23"], port: 50_123))
        XCTAssertEqual(
            try kindBytes(.pointerOpen(grant: 305_419_896, wifi: offer)),
            #"{"pointerOpen":{"grant":305419896,"wifi":{"addrs":["192.168.1.23"],"port":50123}}}"#)
    }

    func testPointerOpenWithoutWifiKeepsTheOldBytes() throws {
        XCTAssertEqual(try kindBytes(.pointerOpen(grant: 305_419_896, wifi: nil)), #"{"pointerOpen":{"grant":305419896}}"#)
    }

    func testSeveralAddressesKeepTheirOrder() throws {
        let offer = try XCTUnwrap(WifiOffer(addrs: ["10.0.0.9", "192.168.1.23", "172.16.4.2"], port: 1))
        XCTAssertEqual(
            try kindBytes(.pointerOpen(grant: 1, wifi: offer)),
            #"{"pointerOpen":{"grant":1,"wifi":{"addrs":["10.0.0.9","192.168.1.23","172.16.4.2"],"port":1}}}"#)
    }

    func testPointerOpenWithWifiRoundTrips() throws {
        let offer = try XCTUnwrap(WifiOffer(addrs: ["192.168.1.23", "10.1.2.3"], port: 65_535))
        for wifi in [offer, nil] {
            let message = PeripheralMessage.event(event(.pointerOpen(grant: 4_294_967_295, wifi: wifi)))
            XCTAssertEqual(try PeripheralCodec.decode(try PeripheralCodec.encode(message)), message)
        }
    }

    // MARK: Decoding

    func testAbsentWifiDecodesToNil() throws {
        XCTAssertEqual(try decodedKind(#"{"pointerOpen":{"grant":7}}"#), .pointerOpen(grant: 7, wifi: nil))
        XCTAssertEqual(try decodedKind(#"{"pointerOpen":{"grant":7,"wifi":null}}"#), .pointerOpen(grant: 7, wifi: nil))
    }

    func testValidWifiDecodes() throws {
        let offer = try XCTUnwrap(WifiOffer(addrs: ["192.168.1.23"], port: 50_123))
        XCTAssertEqual(
            try decodedKind(#"{"pointerOpen":{"grant":7,"wifi":{"addrs":["192.168.1.23"],"port":50123}}}"#),
            .pointerOpen(grant: 7, wifi: offer))
    }

    func testEachInvalidWifiDecodesToNilAndTheEventStaysValid() throws {
        let invalid = [
            #"{"addrs":[],"port":50123}"#,
            #"{"addrs":["10.0.0.1","10.0.0.2","10.0.0.3","10.0.0.4","10.0.0.5"],"port":50123}"#,
            #"{"addrs":["127.0.0.1"],"port":50123}"#,
            #"{"addrs":["127.1.2.3"],"port":50123}"#,
            #"{"addrs":["224.0.0.1"],"port":50123}"#,
            #"{"addrs":["239.255.255.255"],"port":50123}"#,
            #"{"addrs":["255.255.255.255"],"port":50123}"#,
            #"{"addrs":["0.0.0.0"],"port":50123}"#,
            #"{"addrs":["192.168.1.23"],"port":0}"#,
            #"{"addrs":["192.168.1.23"],"port":65536}"#,
            #"{"addrs":["192.168.1.23"],"port":-1}"#,
            #"{"addrs":["192.168.1.23"],"port":"50123"}"#,
            #"{"addrs":["192.168.1.23"]}"#,
            #"{"port":50123}"#,
            #"{"addrs":"192.168.1.23","port":50123}"#,
            #"{"addrs":[1],"port":50123}"#,
            #"{"addrs":["192.168.1.256"],"port":50123}"#,
            #"{"addrs":["192.168.1"],"port":50123}"#,
            #"{"addrs":["192.168.1.23.4"],"port":50123}"#,
            #"{"addrs":["192.168.01.23"],"port":50123}"#,
            #"{"addrs":[" 192.168.1.23"],"port":50123}"#,
            #"{"addrs":["fe80::1"],"port":50123}"#,
            #"{"addrs":["example.com"],"port":50123}"#,
            #"{"addrs":["192.168.1.23","127.0.0.1"],"port":50123}"#,
            #"[]"#,
            #""192.168.1.23""#,
            #"5"#,
        ]
        for wifi in invalid {
            XCTAssertEqual(
                try decodedKind(#"{"pointerOpen":{"grant":7,"wifi":\#(wifi)}}"#), .pointerOpen(grant: 7, wifi: nil), "wifi \(wifi)")
        }
    }

    func testAMalformedGrantIsStillAFormatError() {
        XCTAssertThrowsError(try decodedKind(#"{"pointerOpen":{"wifi":{"addrs":["192.168.1.23"],"port":1}}}"#))
        XCTAssertThrowsError(try decodedKind(#"{"pointerOpen":{"grant":4294967296}}"#))
    }

    func testOtherKindsStillUseTheirWireShapes() throws {
        for (kind, json) in [
            (EventKind.text("A"), #"{"text":{"_0":"A"}}"#),
            (.backspace, #"{"backspace":{}}"#),
            (.returnKey, #"{"returnKey":{}}"#),
            (.probe, #"{"probe":{}}"#),
            (.pointerClose, #"{"pointerClose":{}}"#),
            (.ping(shownAtMs: 120, connectedAtMs: 480), #"{"ping":{"c":480,"s":120}}"#),
        ] {
            XCTAssertEqual(try kindBytes(kind), json)
            XCTAssertEqual(try decodedKind(json), kind)
        }
        XCTAssertThrowsError(try decodedKind(#"{"backspace":{},"probe":{}}"#), "two names are malformed")
        XCTAssertThrowsError(try decodedKind(#"{}"#))
        XCTAssertThrowsError(try decodedKind(#"{"somethingNew":{}}"#))
    }

    // MARK: Validation

    func testValidOffersAreAccepted() {
        XCTAssertNotNil(WifiOffer(addrs: ["192.168.1.23"], port: 50_123))
        XCTAssertNotNil(WifiOffer(addrs: ["10.0.0.1", "10.0.0.2", "10.0.0.3", "10.0.0.4"], port: 1))
        XCTAssertNotNil(WifiOffer(addrs: ["169.254.10.20"], port: 65_535), "link-local is allowed")
        XCTAssertNotNil(WifiOffer(addrs: ["223.255.255.255"], port: 9), "below the multicast range")
        XCTAssertNotNil(WifiOffer(addrs: ["240.0.0.1"], port: 9), "above multicast and not the broadcast address")
        XCTAssertNotNil(WifiOffer(addrs: ["126.255.255.255"], port: 9))
        XCTAssertNotNil(WifiOffer(addrs: ["128.0.0.0"], port: 9))
        XCTAssertNotNil(WifiOffer(addrs: ["0.1.2.3"], port: 9), "only 0.0.0.0 is refused")
    }

    func testInvalidOffersAreRefused() {
        XCTAssertNil(WifiOffer(addrs: [], port: 1))
        XCTAssertNil(WifiOffer(addrs: Array(repeating: "10.0.0.1", count: 5), port: 1))
        XCTAssertNil(WifiOffer(addrs: ["192.168.1.23"], port: 0))
        for bad in ["0.0.0.0", "127.0.0.1", "127.255.255.255", "224.0.0.0", "224.0.0.251", "239.1.2.3", "255.255.255.255",
                    "", "1.2.3", "1.2.3.4.5", "1.2.3.256", "1.2.3.-1", "1.2.3.04", "01.2.3.4", "1.2.3.", ".1.2.3", "1..2.3",
                    "1.2.3.4 ", "+1.2.3.4", "1.2.3.0x4", "1.2.3.٤", "::1", "localhost"] {
            XCTAssertNil(WifiOffer(addrs: [bad], port: 1), "\(bad.debugDescription)")
            XCTAssertNil(WifiOffer(addrs: ["192.168.1.23", bad], port: 1), "a second address \(bad.debugDescription)")
        }
    }
}
