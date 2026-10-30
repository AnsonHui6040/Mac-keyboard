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
        let kinds: [EventKind] = [.text("香港"), .backspace, .returnKey, .ping(shownAtMs: 10, connectedAtMs: 20)]
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
        for kind in [EventKind.text("A"), .backspace, .returnKey] { XCTAssertTrue(kind.carriesFocusEpoch) }
    }

    func testEncodingIsDeterministicSortedKeys() throws {
        let e = makeEvent()
        XCTAssertEqual(try EventCodec.encode(e, maxBytes: 400), try EventCodec.encode(e, maxBytes: 400))
    }

    func testRejectsUnknownVersion() throws {
        let data = try EventCodec.encode(makeEvent(version: 3), maxBytes: 400)
        XCTAssertThrowsError(try EventCodec.decode(data)) { error in
            XCTAssertEqual(error as? EventCodecError, .unsupportedVersion(3))
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
        XCTAssertThrowsError(try EventCodec.decode(Data("{\"protocolVersion\":2}".utf8))) {
            XCTAssertEqual($0 as? EventCodecError, .malformed)
        }
    }
}
