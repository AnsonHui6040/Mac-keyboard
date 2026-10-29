import XCTest
@testable import RemoteKeyboardCore

final class DiagnosticEventTests: XCTestCase {
    func testDiagnosticEventCarriesNoText() { XCTAssertFalse(String(describing: DiagnosticEvent.keySent(kind: .text, utf8Length: 6)).contains("香港")) }

    func testKeyKindRawValues() {
        XCTAssertEqual(DiagnosticKeyKind.text.rawValue, "text")
        XCTAssertEqual(DiagnosticKeyKind.backspace.rawValue, "backspace")
        XCTAssertEqual(DiagnosticKeyKind.return.rawValue, "return")
    }

    func testDropDiagnosticsCarryNoText() {
        let event = DiagnosticEvent.keyDropped(kind: .text, utf8Length: 3, reason: .tooLarge)
        XCTAssertFalse(String(describing: event).contains("香"))
        XCTAssertEqual(KeyDropReason.tooLarge.rawValue, "tooLarge")
        XCTAssertEqual(KeyDropReason.encodeFailed.rawValue, "encodeFailed")
        XCTAssertEqual(DiagnosticEvent.centralSubscribed(maxUpdateLength: 182), .centralSubscribed(maxUpdateLength: 182))
    }

    func testAckCodeRawValues() {
        let raw = [AckCode.posted, .notAuthorized, .noFocus, .staleFocus, .switchFailed, .malformed].map(\.rawValue)
        XCTAssertEqual(raw, ["posted", "notAuthorized", "noFocus", "staleFocus", "switchFailed", "malformed"])
    }

    func testLinkUUIDsAreDistinctValidAndDifferFromReceiverService() {
        let all = [GATTServiceSpec.Link.serviceUUID, GATTServiceSpec.Link.eventUUID, GATTServiceSpec.Link.controlUUID]
        XCTAssertEqual(Set(all).count, 3)
        all.forEach { XCTAssertNotNil(UUID(uuidString: $0)) }
        XCTAssertNotEqual(GATTServiceSpec.Link.serviceUUID, GATTServiceSpec.serviceUUID)
    }
}
