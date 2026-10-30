import XCTest
@testable import RemoteKeyboardCore

final class SessionPinTests: XCTestCase {
    func testFirstSessionIdIsPinnedAndRepeatsAreAccepted() {
        var pin = SessionPin()
        let session = UUID()
        XCTAssertTrue(pin.accept(session))
        XCTAssertTrue(pin.accept(session))
        XCTAssertTrue(pin.accept(session))
    }

    func testADifferentSessionIdIsRefusedAndStaysRefused() {
        var pin = SessionPin()
        let first = UUID()
        XCTAssertTrue(pin.accept(first))
        XCTAssertFalse(pin.accept(UUID()))
        XCTAssertTrue(pin.accept(first), "a refusal does not move the pin")
    }

    func testANewPinStartsFree() {
        var pin = SessionPin()
        _ = pin.accept(UUID())
        pin = SessionPin()
        XCTAssertTrue(pin.accept(UUID()))
    }
}
