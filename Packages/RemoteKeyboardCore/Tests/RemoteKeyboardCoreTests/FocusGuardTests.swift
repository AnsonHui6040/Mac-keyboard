import XCTest
@testable import RemoteKeyboardCore

private func snap(ax: Bool = true, editable: Bool = true, epoch: UInt64 = 1) -> FocusSnapshot {
    FocusSnapshot(axTrusted: ax, frontmostPID: 100, appName: "TextEdit", editable: editable, epoch: epoch)
}

final class FocusGuardTests: XCTestCase {
    func testAXUntrustedRejectsInsertion() { XCTAssertEqual(FocusGuard.authorize(eventEpoch: 1, current: snap(ax: false)), .notAuthorized) }
    func testNoEditableFocusRejectsInsertion() { XCTAssertEqual(FocusGuard.authorize(eventEpoch: 1, current: snap(editable: false)), .noFocus) }
    func testEpochChangedRejectsInsertion() { XCTAssertEqual(FocusGuard.authorize(eventEpoch: 1, current: snap(epoch: 2)), .staleFocus) }
    func testMatchingEpochAllows() { XCTAssertEqual(FocusGuard.authorize(eventEpoch: 2, current: snap(epoch: 2)), .allow) }

    func testMissingSnapshotIsNotAuthorized() { XCTAssertEqual(FocusGuard.authorize(eventEpoch: nil, current: nil), .notAuthorized) }
    func testNilEpochSkipsStalenessCheck() { XCTAssertEqual(FocusGuard.authorize(eventEpoch: nil, current: snap(epoch: 9)), .allow) }
    func testUntrustedWinsOverNoFocus() {
        XCTAssertEqual(FocusGuard.authorize(eventEpoch: 1, current: snap(ax: false, editable: false)), .notAuthorized)
    }
    func testNoFocusWinsOverStaleEpoch() {
        XCTAssertEqual(FocusGuard.authorize(eventEpoch: 1, current: snap(editable: false, epoch: 2)), .noFocus)
    }
}
