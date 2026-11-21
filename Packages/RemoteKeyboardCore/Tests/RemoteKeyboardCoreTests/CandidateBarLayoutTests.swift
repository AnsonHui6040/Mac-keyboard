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

    // MARK: Manual strip layout (no Auto Layout in the candidate row)

    func testStripWithNothingIsEmpty() {
        let strip = CandidateBarLayout.strip(composingTextWidth: nil, candidateTextWidths: [], height: 36)
        XCTAssertNil(strip.composing)
        XCTAssertTrue(strip.candidates.isEmpty)
        XCTAssertEqual(strip.contentWidth, 0)
    }

    func testStripWithOnlyTheCodeUsesMinimumWidthAndMargins() throws {
        let strip = CandidateBarLayout.strip(composingTextWidth: 20, candidateTextWidths: [], height: 36)
        let code = try XCTUnwrap(strip.composing)
        XCTAssertEqual(code, CandidateBarLayout.StripRect(x: 6, y: 3, width: 44, height: 30))
        XCTAssertTrue(strip.candidates.isEmpty)
        XCTAssertEqual(strip.contentWidth, 6 + 44 + 6)
    }

    func testStripCodeWiderThanMinimumRoundsUp() throws {
        let strip = CandidateBarLayout.strip(composingTextWidth: 60.2, candidateTextWidths: [], height: 36)
        XCTAssertEqual(try XCTUnwrap(strip.composing).width, 61)
    }

    func testStripWithOnlyCandidatesAddsInsetsAndGaps() {
        let strip = CandidateBarLayout.strip(composingTextWidth: nil, candidateTextWidths: [22.4, 44], height: 36)
        XCTAssertNil(strip.composing)
        XCTAssertEqual(strip.candidates, [
            CandidateBarLayout.StripRect(x: 6, y: 3, width: 43, height: 30),
            CandidateBarLayout.StripRect(x: 53, y: 3, width: 64, height: 30)
        ])
        XCTAssertEqual(strip.contentWidth, 117 + 6)
    }

    func testStripSmallTextTriggersMinimumCandidateWidth() {
        // A 10 pt wide glyph plus 20 pt of inset is 30, below the 40 pt minimum.
        let strip = CandidateBarLayout.strip(composingTextWidth: nil, candidateTextWidths: [10], height: 36)
        XCTAssertEqual(strip.candidates.first?.width, 40)
    }

    func testStripPlacesCandidatesAfterTheCodeWithOneGap() throws {
        let strip = CandidateBarLayout.strip(composingTextWidth: 30, candidateTextWidths: [22], height: 40)
        let code = try XCTUnwrap(strip.composing)
        XCTAssertEqual(code.width, 44)
        XCTAssertEqual(code.height, 34)
        XCTAssertEqual(strip.candidates, [CandidateBarLayout.StripRect(x: 6 + 44 + 4, y: 3, width: 42, height: 34)])
        XCTAssertEqual(strip.contentWidth, 54 + 42 + 6)
    }

    func testStripOfTwoHundredCandidatesAddsUp() {
        let strip = CandidateBarLayout.strip(
            composingTextWidth: 20, candidateTextWidths: Array(repeating: 22.0, count: 200), height: 36)
        XCTAssertEqual(strip.candidates.count, 200)
        // 6 + code 44, then 200 * (42 + 4 gap before each), then 6.
        let expectedWidth: Double = 6 + 44 + 200 * 46 + 6
        XCTAssertEqual(strip.contentWidth, expectedWidth)
        let last = strip.candidates[199]
        let expectedRight: Double = 6 + 44 + 200 * 46
        XCTAssertEqual(last.x + last.width, expectedRight)
    }
}
