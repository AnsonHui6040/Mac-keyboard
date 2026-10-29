import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

final class FocusTransitionTests: XCTestCase {
    private func snap(_ editable: Bool, epoch: UInt64, app: String? = "TextEdit", trusted: Bool = true) -> FocusSnapshot {
        FocusSnapshot(axTrusted: trusted, frontmostPID: 1, appName: app, editable: editable, epoch: epoch)
    }

    func testGainedEditableOnFirstEditableSnapshot() {
        XCTAssertTrue(FocusTransition.gainedEditable(previous: nil, next: snap(true, epoch: 1)))
        XCTAssertFalse(FocusTransition.gainedEditable(previous: nil, next: snap(false, epoch: 1)))
    }

    func testGainedEditableWhenPreviousWasNotEditable() {
        XCTAssertTrue(FocusTransition.gainedEditable(previous: snap(false, epoch: 3), next: snap(true, epoch: 3)))
    }

    func testGainedEditableWhenEpochChangedWhileEditable() {
        XCTAssertTrue(FocusTransition.gainedEditable(previous: snap(true, epoch: 3), next: snap(true, epoch: 4)))
    }

    func testNoGainWhenStillTheSameEditableField() {
        XCTAssertFalse(FocusTransition.gainedEditable(previous: snap(true, epoch: 3), next: snap(true, epoch: 3, app: "Renamed")))
    }

    func testNoGainWhenNextIsNotEditable() {
        XCTAssertFalse(FocusTransition.gainedEditable(previous: snap(true, epoch: 3), next: snap(false, epoch: 4)))
    }

    func testStatusChangesOnEpochEditableAppOrTrust() {
        let base = snap(true, epoch: 3)
        XCTAssertTrue(FocusTransition.statusChanged(previous: nil, next: base))
        XCTAssertTrue(FocusTransition.statusChanged(previous: base, next: snap(true, epoch: 4)))
        XCTAssertTrue(FocusTransition.statusChanged(previous: base, next: snap(false, epoch: 3)))
        XCTAssertTrue(FocusTransition.statusChanged(previous: base, next: snap(true, epoch: 3, app: "Notes")))
        XCTAssertTrue(FocusTransition.statusChanged(previous: base, next: snap(true, epoch: 3, trusted: false)))
        XCTAssertFalse(FocusTransition.statusChanged(previous: base, next: snap(true, epoch: 3)))
    }

    func testStatusReadyNeedsTrustAndEditable() {
        XCTAssertTrue(FocusTransition.status(for: snap(true, epoch: 7)).ready)
        XCTAssertFalse(FocusTransition.status(for: snap(false, epoch: 7)).ready)
        XCTAssertFalse(FocusTransition.status(for: snap(true, epoch: 7, trusted: false)).ready)
        XCTAssertEqual(FocusTransition.status(for: snap(true, epoch: 7)).focusEpoch, 7)
    }

    func testLongAppNamesAreCut() {
        let long = String(repeating: "名", count: 100)
        XCTAssertEqual(FocusTransition.status(for: snap(true, epoch: 1, app: long)).appName?.count, FocusTransition.maxAppNameLength)
        XCTAssertNil(FocusTransition.status(for: snap(true, epoch: 1, app: nil)).appName)
    }
}
