import XCTest
@testable import RemoteKeyboardCore

final class EventCodecTests: XCTestCase {
    private func makeEvent(version: Int = 1, kind: EventKind = .text("A"), epoch: UInt64? = 7) -> KeyboardEvent {
        KeyboardEvent(protocolVersion: version, eventId: UUID(), sessionId: UUID(), seq: 1, focusEpoch: epoch, kind: kind)
    }

    func testTextARoundTrip() throws {
        let e = KeyboardEvent(protocolVersion: 1, eventId: UUID(), sessionId: UUID(), seq: 1, focusEpoch: 7, kind: .text("A"))
        XCTAssertEqual(try EventCodec.decode(EventCodec.encode(e, maxBytes: 182)), e)
    }

    func testEveryKindRoundTripsIncludingNilEpoch() throws {
        let kinds: [EventKind] = [.text("香港"), .backspace, .returnKey, .ping(shownAtMs: 10, connectedAtMs: 20)]
        for kind in kinds {
            let e = makeEvent(kind: kind, epoch: nil)
            XCTAssertEqual(try EventCodec.decode(EventCodec.encode(e, maxBytes: 400)), e)
        }
    }

    func testCurrentVersionIsOne() { XCTAssertEqual(KeyboardEvent.currentVersion, 1) }

    func testEncodingIsDeterministicSortedKeys() throws {
        let e = makeEvent()
        XCTAssertEqual(try EventCodec.encode(e, maxBytes: 400), try EventCodec.encode(e, maxBytes: 400))
    }

    func testRejectsUnknownVersion() throws {
        let data = try EventCodec.encode(makeEvent(version: 2), maxBytes: 400)
        XCTAssertThrowsError(try EventCodec.decode(data)) { error in
            XCTAssertEqual(error as? EventCodecError, .unsupportedVersion(2))
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
        XCTAssertThrowsError(try EventCodec.decode(Data("{\"protocolVersion\":1}".utf8))) {
            XCTAssertEqual($0 as? EventCodecError, .malformed)
        }
    }
}
