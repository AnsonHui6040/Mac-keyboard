import XCTest
@testable import RemoteKeyboardCore

final class CandidateBarLayoutTests: XCTestCase {
    func testScrollAreaWithoutBackspaceIsTheWholeRow() {
        let layout = CandidateBarLayout.frames(totalWidth: 402, showsBackspace: false)
        XCTAssertEqual(layout.scrollWidth, 402)
        XCTAssertNil(layout.backspace)
    }

    func testScrollAreaWithBackspaceStopsOneGapBeforeIt() throws {
        let total = 402.0
        let layout = CandidateBarLayout.frames(totalWidth: total, showsBackspace: true)
        let backspace = try XCTUnwrap(layout.backspace)
        XCTAssertEqual(backspace.width, CandidateBarLayout.backspaceWidth)
        // The delete key sits against the right edge, inside the row's trailing margin.
        XCTAssertEqual(backspace.x + backspace.width, total - CandidateBarLayout.trailingInset)
        // Scroll width = total - delete width - gap (the trailing margin is part of the delete key's slot).
        XCTAssertEqual(
            layout.scrollWidth,
            total - CandidateBarLayout.backspaceWidth - CandidateBarLayout.gap - CandidateBarLayout.trailingInset)
        XCTAssertEqual(layout.scrollWidth, backspace.x - CandidateBarLayout.gap)
    }

    func testBackspaceKeyFitsInsideTheTopRowHeight() {
        XCTAssertEqual(CandidateBarLayout.backspaceHeight, KeyboardMetrics.topRowHeight - 2 * CandidateBarLayout.verticalInset)
        XCTAssertEqual(CandidateBarLayout.rowHeight, 36)
        XCTAssertEqual(CandidateBarLayout.rowHeight, KeyboardMetrics.topRowHeight)
    }

    func testScrollAreaStaysPositiveOnNarrowAndWidePhones() {
        for width in [375.0, 402.0] {
            XCTAssertGreaterThan(CandidateBarLayout.frames(totalWidth: width, showsBackspace: true).scrollWidth, 0)
        }
        XCTAssertEqual(CandidateBarLayout.frames(totalWidth: 10, showsBackspace: true).scrollWidth, 0)
    }
}
