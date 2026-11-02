import XCTest
@testable import RemoteKeyboardCore

final class TopAreaStateTests: XCTestCase {
    private func state(
        _ mode: KeyboardMode, _ transmit: TransmitMode = .instant, ready: Bool = true,
        draftEmpty: Bool = true, hasNote: Bool = false, candidates: Bool = false
    ) -> TopAreaState {
        TopAreaState(
            mode: mode, transmit: transmit, ready: ready, draftEmpty: draftEmpty, hasNote: hasNote, showsCandidates: candidates)
    }

    func testRemoteInstantReadyEmptyShowsOneRow() {
        let s = state(.remote)
        XCTAssertTrue(s.showsStatus); XCTAssertTrue(s.showsTransmitToggle)
        XCTAssertFalse(s.showsDraftRow); XCTAssertFalse(s.showsCandidateRow)
        XCTAssertFalse(s.sendEnabled); XCTAssertEqual(s.visibleRowCount, 1)
    }

    func testTrackpadKeyIsShownInRemoteModeOnly() {
        for transmit in [TransmitMode.instant, .draft] {
            XCTAssertTrue(state(.remote, transmit).showsTrackpadKey)
            XCTAssertFalse(state(.local, transmit, hasNote: true).showsTrackpadKey)
        }
    }

    func testCandidateRowFollowsTheParameterInBothModes() {
        for mode in [KeyboardMode.local, .remote] {
            XCTAssertFalse(state(mode, candidates: false).showsCandidateRow)
            XCTAssertTrue(state(mode, candidates: true).showsCandidateRow)
            XCTAssertEqual(state(mode, candidates: true).visibleRowCount, 2)
        }
        XCTAssertEqual(state(.remote, .draft, candidates: true).visibleRowCount, 3)
    }

    func testRemoteDraftModeShowsDraftRowEvenWhenReadyAndEmpty() {
        let s = state(.remote, .draft)
        XCTAssertTrue(s.showsDraftRow); XCTAssertEqual(s.visibleRowCount, 2)
        XCTAssertFalse(s.sendEnabled)
    }

    func testRemoteInstantKeepsNonEmptyDraftVisible() {
        let s = state(.remote, .instant, draftEmpty: false)
        XCTAssertTrue(s.showsDraftRow); XCTAssertTrue(s.sendEnabled); XCTAssertEqual(s.visibleRowCount, 2)
    }

    func testRemoteInstantNotReadyAndEmptyShowsNoDraftRow() {
        let s = state(.remote, .instant, ready: false)
        XCTAssertFalse(s.showsDraftRow); XCTAssertFalse(s.sendEnabled); XCTAssertEqual(s.visibleRowCount, 1)
    }

    func testRemoteNotReadyWithDraftTextShowsTheRowWithSendDisabled() {
        for transmit in [TransmitMode.instant, .draft] {
            let withText = state(.remote, transmit, ready: false, draftEmpty: false)
            XCTAssertTrue(withText.showsDraftRow); XCTAssertFalse(withText.sendEnabled)
        }
        let draftMode = state(.remote, .draft, ready: false)
        XCTAssertTrue(draftMode.showsDraftRow); XCTAssertFalse(draftMode.sendEnabled)
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
                XCTAssertFalse(s.showsCandidateRow)
                XCTAssertEqual(s.visibleRowCount, 1)
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

    func testVisibleRowCountIsOneToThree() {
        for mode in [KeyboardMode.local, .remote] {
            for transmit in [TransmitMode.instant, .draft] {
                for ready in [true, false] {
                    for draftEmpty in [true, false] {
                        for hasNote in [true, false] {
                            for candidates in [true, false] {
                                let n = state(
                                    mode, transmit, ready: ready, draftEmpty: draftEmpty, hasNote: hasNote,
                                    candidates: candidates).visibleRowCount
                                XCTAssertTrue((1...3).contains(n))
                            }
                        }
                    }
                }
            }
        }
    }

    func testMetricsConstantsAndHeights() {
        XCTAssertEqual(KeyboardMetrics.topRowHeight, 36)
        XCTAssertEqual(KeyboardMetrics.keyRowHeight, 42)
        XCTAssertEqual(KeyboardMetrics.rowGap, 12)
        XCTAssertEqual(KeyboardMetrics.keyRowCount, 4)
        XCTAssertEqual(KeyboardMetrics.keyAreaHeight, 4 * 42 + 3 * 12 + 8)
        XCTAssertEqual(KeyboardMetrics.height(visibleTopRows: 2), 2 * 36 + 212)
        XCTAssertEqual(KeyboardMetrics.height(visibleTopRows: 3), 3 * 36 + 212)
        XCTAssertEqual(KeyboardMetrics.height(visibleTopRows: 3) - KeyboardMetrics.height(visibleTopRows: 2), 36)
    }

    func testHandwritingPageIsSixtyPointsTaller() {
        XCTAssertEqual(KeyboardMetrics.handwritingExtraHeight, 60)
        XCTAssertEqual(KeyboardMetrics.height(visibleTopRows: 2, handwriting: true), 344)
        XCTAssertEqual(KeyboardMetrics.height(visibleTopRows: 3, handwriting: true), 380)
        XCTAssertEqual(KeyboardMetrics.height(visibleTopRows: 2, handwriting: false), 284)
        XCTAssertEqual(KeyboardMetrics.height(visibleTopRows: 3, handwriting: false), 320)
        XCTAssertEqual(KeyboardMetrics.height(visibleTopRows: 2), 284)
        XCTAssertEqual(3 * KeyboardMetrics.keyRowHeight + 2 * KeyboardMetrics.rowGap + KeyboardMetrics.handwritingExtraHeight, 210)
    }
}
