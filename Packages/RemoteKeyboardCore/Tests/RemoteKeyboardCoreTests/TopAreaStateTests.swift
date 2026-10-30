import XCTest
@testable import RemoteKeyboardCore

final class TopAreaStateTests: XCTestCase {
    private func state(
        _ mode: KeyboardMode, _ transmit: TransmitMode = .instant, ready: Bool = true,
        draftEmpty: Bool = true, hasNote: Bool = false
    ) -> TopAreaState {
        TopAreaState(mode: mode, transmit: transmit, ready: ready, draftEmpty: draftEmpty, hasNote: hasNote)
    }

    func testRemoteInstantReadyEmptyShowsTwoRows() {
        let s = state(.remote)
        XCTAssertTrue(s.showsStatus); XCTAssertTrue(s.showsTransmitToggle)
        XCTAssertFalse(s.showsDraftRow); XCTAssertTrue(s.showsCandidateRow)
        XCTAssertFalse(s.sendEnabled); XCTAssertEqual(s.visibleRowCount, 2)
    }

    func testRemoteDraftModeShowsDraftRowEvenWhenReadyAndEmpty() {
        let s = state(.remote, .draft)
        XCTAssertTrue(s.showsDraftRow); XCTAssertEqual(s.visibleRowCount, 3)
        XCTAssertFalse(s.sendEnabled)
    }

    func testRemoteInstantKeepsNonEmptyDraftVisible() {
        let s = state(.remote, .instant, draftEmpty: false)
        XCTAssertTrue(s.showsDraftRow); XCTAssertTrue(s.sendEnabled); XCTAssertEqual(s.visibleRowCount, 3)
    }

    func testRemoteInstantNotReadyShowsDraftRowWithSendDisabled() {
        let s = state(.remote, .instant, ready: false)
        XCTAssertTrue(s.showsDraftRow); XCTAssertFalse(s.sendEnabled); XCTAssertEqual(s.visibleRowCount, 3)
        let withText = state(.remote, .instant, ready: false, draftEmpty: false)
        XCTAssertFalse(withText.sendEnabled)
    }

    func testRemoteDraftReadyWithTextEnablesSend() {
        XCTAssertTrue(state(.remote, .draft, ready: true, draftEmpty: false).sendEnabled)
    }

    func testLocalShowsStatusOnlyWithANote() {
        XCTAssertFalse(state(.local).showsStatus)
        XCTAssertTrue(state(.local, hasNote: true).showsStatus)
    }

    func testLocalHidesTransmitToggleAndDraftRowAndDisablesSend() {
        for transmit in [TransmitMode.instant, .draft] {
            for draftEmpty in [true, false] {
                let s = state(.local, transmit, ready: false, draftEmpty: draftEmpty)
                XCTAssertFalse(s.showsTransmitToggle)
                XCTAssertFalse(s.showsDraftRow)
                XCTAssertFalse(s.sendEnabled)
                XCTAssertTrue(s.showsCandidateRow)
                XCTAssertEqual(s.visibleRowCount, 2)
            }
        }
    }

    func testRemoteStatusAndToggleAreAlwaysShown() {
        for transmit in [TransmitMode.instant, .draft] {
            for ready in [true, false] {
                let s = state(.remote, transmit, ready: ready)
                XCTAssertTrue(s.showsStatus); XCTAssertTrue(s.showsTransmitToggle)
            }
        }
    }

    func testVisibleRowCountIsAlwaysTwoOrThree() {
        for mode in [KeyboardMode.local, .remote] {
            for transmit in [TransmitMode.instant, .draft] {
                for ready in [true, false] {
                    for draftEmpty in [true, false] {
                        for hasNote in [true, false] {
                            let n = state(mode, transmit, ready: ready, draftEmpty: draftEmpty, hasNote: hasNote).visibleRowCount
                            XCTAssertTrue(n == 2 || n == 3)
                        }
                    }
                }
            }
        }
    }

    func testMetricsConstantsAndHeights() {
        XCTAssertEqual(KeyboardMetrics.topRowHeight, 36)
        XCTAssertEqual(KeyboardMetrics.keyRowHeight, 46)
        XCTAssertEqual(KeyboardMetrics.rowGap, 10)
        XCTAssertEqual(KeyboardMetrics.keyRowCount, 4)
        XCTAssertEqual(KeyboardMetrics.keyAreaHeight, 4 * 46 + 3 * 10 + 8)
        XCTAssertEqual(KeyboardMetrics.height(visibleTopRows: 2), 2 * 36 + 222)
        XCTAssertEqual(KeyboardMetrics.height(visibleTopRows: 3), 3 * 36 + 222)
        XCTAssertEqual(KeyboardMetrics.height(visibleTopRows: 3) - KeyboardMetrics.height(visibleTopRows: 2), 36)
    }
}
