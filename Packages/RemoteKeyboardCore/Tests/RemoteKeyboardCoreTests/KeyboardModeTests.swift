import XCTest
@testable import RemoteKeyboardCore

final class KeyboardModeTests: XCTestCase {
    func testSavedRemoteFallsBackToLocalWithoutFullAccess() {
        XCTAssertEqual(ModeResolver.effectiveMode(saved: .remote, hasFullAccess: false), .local)
        XCTAssertEqual(ModeResolver.effectiveMode(saved: .remote, hasFullAccess: true), .remote)
    }

    func testSavedLocalStaysLocalEitherWay() {
        XCTAssertEqual(ModeResolver.effectiveMode(saved: .local, hasFullAccess: false), .local)
        XCTAssertEqual(ModeResolver.effectiveMode(saved: .local, hasFullAccess: true), .local)
    }

    func testStoredRawValueDecodesAndUnknownFallsBackToLocal() {
        XCTAssertEqual(ModeResolver.saved(rawValue: "remote"), .remote)
        XCTAssertEqual(ModeResolver.saved(rawValue: "local"), .local)
        XCTAssertEqual(ModeResolver.saved(rawValue: nil), .local)
        XCTAssertEqual(ModeResolver.saved(rawValue: "garbage"), .local)
    }
}
