import XCTest
@testable import RemoteKeyboardCore

final class DraftBufferTests: XCTestCase {
    func testStartsEmptyWithCursorAtZero() {
        let draft = DraftBuffer()
        XCTAssertTrue(draft.isEmpty)
        XCTAssertEqual(draft.text, "")
        XCTAssertEqual(draft.cursor, 0)
    }

    func testInsertAppendsAndMovesCursor() {
        var draft = DraftBuffer()
        XCTAssertTrue(draft.insert("香港"))
        XCTAssertEqual(draft.text, "香港")
        XCTAssertEqual(draft.cursor, 2)
        XCTAssertFalse(draft.isEmpty)
    }

    func testCursorInsertsInMiddleByGrapheme() {
        var draft = DraftBuffer()
        _ = draft.insert("香港你好")
        draft.moveLeft(); draft.moveLeft()
        XCTAssertEqual(draft.cursor, 2)
        XCTAssertTrue(draft.insert("人"))
        XCTAssertEqual(draft.text, "香港人你好")
        XCTAssertEqual(draft.cursor, 3)
    }

    func testCursorCountsAFamilyEmojiAsOneCharacter() {
        var draft = DraftBuffer()
        _ = draft.insert("a👨‍👩‍👧‍👦b")
        XCTAssertEqual(draft.cursor, 3)
        draft.moveLeft()
        draft.moveLeft()
        XCTAssertEqual(draft.cursor, 1)
        draft.deleteBackward()
        XCTAssertEqual(draft.text, "👨‍👩‍👧‍👦b")
        XCTAssertEqual(draft.cursor, 0)
    }

    func testDeleteBackwardRemovesTheCharacterBeforeTheCursor() {
        var draft = DraftBuffer()
        _ = draft.insert("香港你好")
        draft.moveLeft()
        draft.deleteBackward()
        XCTAssertEqual(draft.text, "香港好")
        XCTAssertEqual(draft.cursor, 2)
    }

    func testDeleteBackwardAtStartChangesNothing() {
        var draft = DraftBuffer()
        _ = draft.insert("ab")
        draft.moveLeft(); draft.moveLeft()
        draft.deleteBackward()
        XCTAssertEqual(draft.text, "ab")
        XCTAssertEqual(draft.cursor, 0)
    }

    func testMovesStopAtBothEnds() {
        var draft = DraftBuffer()
        _ = draft.insert("ab")
        draft.moveRight()
        XCTAssertEqual(draft.cursor, 2)
        draft.moveLeft(); draft.moveLeft(); draft.moveLeft()
        XCTAssertEqual(draft.cursor, 0)
    }

    func testDraftCapRejectsOverflow() {
        var draft = DraftBuffer()
        for _ in 0..<DraftBuffer.maxCharacters { XCTAssertTrue(draft.insert("a")) }
        XCTAssertEqual(DraftBuffer.maxCharacters, 1_000)
        XCTAssertFalse(draft.insert("b"))
        XCTAssertEqual(draft.text.count, 1_000)
        XCTAssertEqual(draft.cursor, 1_000)
        XCTAssertFalse(draft.text.contains("b"))
    }

    func testOverflowingMultiCharacterInsertIsRefusedWholeAndLeavesDraftUnchanged() {
        var draft = DraftBuffer()
        _ = draft.insert(String(repeating: "a", count: 999))
        XCTAssertFalse(draft.insert("bc"))
        XCTAssertEqual(draft.text.count, 999)
        XCTAssertTrue(draft.insert("b"))
        XCTAssertEqual(draft.text.count, 1_000)
    }

    func testTakeEventsSplitsOnNewlines() {
        var draft = DraftBuffer()
        _ = draft.insert("ab\ncd")
        XCTAssertEqual(draft.takeEvents(), [.text("ab"), .returnKey, .text("cd")])
        XCTAssertTrue(draft.isEmpty)
        XCTAssertEqual(draft.cursor, 0)
    }

    func testTakeEventsMakesNoEmptyTextAndKeepsEveryReturn() {
        var draft = DraftBuffer()
        _ = draft.insert("\n\n")
        XCTAssertEqual(draft.takeEvents(), [.returnKey, .returnKey])
        _ = draft.insert("\na\n")
        XCTAssertEqual(draft.takeEvents(), [.returnKey, .text("a"), .returnKey])
    }

    func testTakeEventsOfAnEmptyDraftIsEmpty() {
        var draft = DraftBuffer()
        XCTAssertEqual(draft.takeEvents(), [])
    }

    func testTakeEventsChunksLongTextByBytesOnGraphemeBoundaries() {
        var draft = DraftBuffer()
        let family = "👨‍👩‍👧‍👦"
        let original = String(repeating: family, count: 1_000)
        XCTAssertTrue(draft.insert(original))
        let events = draft.takeEvents()
        var joined = ""
        for event in events {
            guard case .text(let text) = event else { return XCTFail("only text expected, got \(event)") }
            XCTAssertFalse(text.isEmpty)
            XCTAssertLessThanOrEqual(text.utf8.count, DraftBuffer.maxEventBytes)
            joined += text
        }
        XCTAssertEqual(joined, original)
        XCTAssertGreaterThan(events.count, 1)
        // A chunk never starts or ends inside a family emoji: every chunk is a whole number of them.
        for event in events {
            if case .text(let text) = event { XCTAssertEqual(text.count * family.utf8.count, text.utf8.count) }
        }
    }

    func testASegmentOfExactlyTheByteLimitIsOneEventBeforeTheLineBreak() {
        var draft = DraftBuffer()
        // 666 three-byte characters plus two ASCII ones: 2,000 bytes in 668 characters, under the 1,000 character cap.
        let exact = String(repeating: "一", count: 666) + "ab"
        XCTAssertEqual(exact.utf8.count, 2_000)
        XCTAssertTrue(draft.insert(exact + "\nrest"))
        XCTAssertEqual(draft.takeEvents(), [.text(exact), .returnKey, .text("rest")])
    }

    func testTextAroundTheCursor() {
        var draft = DraftBuffer()
        _ = draft.insert("香港你好")
        draft.moveLeft(); draft.moveLeft()
        XCTAssertEqual(draft.textBeforeCursor, "香港")
        XCTAssertEqual(draft.textAfterCursor, "你好")
    }

    // MARK: moveCursor

    func testMoveCursorSetsTheIndexAndTypingFollowsIt() {
        var draft = DraftBuffer()
        _ = draft.insert("abcd")
        draft.moveCursor(to: 2)
        XCTAssertEqual(draft.cursor, 2)
        XCTAssertEqual(draft.textBeforeCursor, "ab"); XCTAssertEqual(draft.textAfterCursor, "cd")
        XCTAssertTrue(draft.insert("X"))
        XCTAssertEqual(draft.text, "abXcd"); XCTAssertEqual(draft.cursor, 3)
        draft.deleteBackward()
        XCTAssertEqual(draft.text, "abcd"); XCTAssertEqual(draft.cursor, 2)
    }

    func testMoveCursorClampsToTheTextLength() {
        var draft = DraftBuffer()
        _ = draft.insert("abc")
        draft.moveCursor(to: -5)
        XCTAssertEqual(draft.cursor, 0)
        draft.moveCursor(to: 99)
        XCTAssertEqual(draft.cursor, 3)
        var empty = DraftBuffer()
        empty.moveCursor(to: 4)
        XCTAssertEqual(empty.cursor, 0)
    }

    func testMoveCursorCountsCharactersNotScalars() {
        var draft = DraftBuffer()
        _ = draft.insert("a👨‍👩‍👧‍👦b")
        draft.moveCursor(to: 2)
        XCTAssertEqual(draft.textBeforeCursor, "a👨‍👩‍👧‍👦"); XCTAssertEqual(draft.textAfterCursor, "b")
        draft.moveCursor(to: 1)
        XCTAssertEqual(draft.textBeforeCursor, "a")
    }

    func testMoveCursorKeepsTheTextAndTheCap() {
        var draft = DraftBuffer()
        _ = draft.insert(String(repeating: "a", count: DraftBuffer.maxCharacters))
        draft.moveCursor(to: 10)
        XCTAssertEqual(draft.text.count, DraftBuffer.maxCharacters)
        XCTAssertFalse(draft.insert("b"))
    }
}

final class DraftCaretHitTestTests: XCTestCase {
    private typealias Stop = DraftCaretHitTest.Stop
    private let widths = [10.0, 10, 10, 10]   // "abcd", each 10 pt wide

    func testNearestBoundaryOfAPlainDraft() {
        let stops = DraftCaretHitTest.stopsAfter(
            widths: widths, originX: 8, available: 200, ellipsis: 8, baseIndex: 0)
        XCTAssertEqual(stops.map(\.index), [0, 1, 2, 3, 4])
        XCTAssertEqual(stops.map(\.x), [8, 18, 28, 38, 48])
        XCTAssertEqual(DraftCaretHitTest.nearestIndex(x: 8, stops: stops), 0)
        XCTAssertEqual(DraftCaretHitTest.nearestIndex(x: 22, stops: stops), 1)
        XCTAssertEqual(DraftCaretHitTest.nearestIndex(x: 23.5, stops: stops), 2)
        XCTAssertEqual(DraftCaretHitTest.nearestIndex(x: 47, stops: stops), 4)
    }

    func testTouchesOutsideTheTextGoToTheEnds() {
        let stops = DraftCaretHitTest.stopsAfter(widths: widths, originX: 8, available: 200, ellipsis: 8, baseIndex: 0)
        XCTAssertEqual(DraftCaretHitTest.nearestIndex(x: -50, stops: stops), 0)
        XCTAssertEqual(DraftCaretHitTest.nearestIndex(x: 400, stops: stops), 4)
    }

    func testAHalfwayTouchGoesToTheEarlierBoundary() {
        let stops = DraftCaretHitTest.stopsAfter(widths: widths, originX: 0, available: 200, ellipsis: 8, baseIndex: 0)
        XCTAssertEqual(DraftCaretHitTest.nearestIndex(x: 5, stops: stops), 0)
        XCTAssertEqual(DraftCaretHitTest.nearestIndex(x: 15, stops: stops), 1)
    }

    func testNoStopsMeansNoIndex() {
        XCTAssertNil(DraftCaretHitTest.nearestIndex(x: 10, stops: []))
    }

    func testTextAfterTheCaretCutAtItsTailKeepsOnlyWhatFitsPlusTheEllipsis() {
        // Room for 3 characters and the ellipsis (3 x 10 + 8 = 38 <= 39), not for all 4 (40).
        let stops = DraftCaretHitTest.stopsAfter(widths: widths, originX: 100, available: 39, ellipsis: 8, baseIndex: 5)
        XCTAssertEqual(stops.map(\.index), [5, 6, 7, 8])
        XCTAssertEqual(stops.map(\.x), [100, 110, 120, 130])
        // A touch on the ellipsis lands on the last visible boundary.
        XCTAssertEqual(DraftCaretHitTest.nearestIndex(x: 138, stops: stops), 8)
    }

    func testAfterTextThatFitsExactlyHasNoEllipsis() {
        let stops = DraftCaretHitTest.stopsAfter(widths: widths, originX: 0, available: 40, ellipsis: 30, baseIndex: 0)
        XCTAssertEqual(stops.map(\.index), [0, 1, 2, 3, 4])
    }

    func testAfterLabelWithNoRoomOffersOnlyTheCaretPosition() {
        let stops = DraftCaretHitTest.stopsAfter(widths: widths, originX: 100, available: 0, ellipsis: 8, baseIndex: 2)
        XCTAssertEqual(stops, [Stop(x: 100, index: 2)])
    }

    func testTextBeforeTheCaretCutAtItsHeadStartsAfterTheEllipsis() {
        // Four characters before the caret (indices 0..4), room for the ellipsis and two of them: 8 + 20 <= 30.
        let stops = DraftCaretHitTest.stopsBefore(widths: widths, originX: 8, available: 30, ellipsis: 8)
        XCTAssertEqual(stops.map(\.index), [2, 3, 4])
        XCTAssertEqual(stops.map(\.x), [16, 26, 36])
        // The ellipsis itself maps to the first visible boundary, never to a hidden one.
        XCTAssertEqual(DraftCaretHitTest.nearestIndex(x: 8, stops: stops), 2)
    }

    func testBeforeTextThatFitsKeepsEveryBoundary() {
        let stops = DraftCaretHitTest.stopsBefore(widths: widths, originX: 8, available: 100, ellipsis: 8)
        XCTAssertEqual(stops.map(\.index), [0, 1, 2, 3, 4])
        XCTAssertEqual(stops.last?.x, 48)
    }

    func testBeforeLabelNarrowerThanTheEllipsisStillOffersTheCaret() {
        let stops = DraftCaretHitTest.stopsBefore(widths: widths, originX: 8, available: 5, ellipsis: 8)
        XCTAssertEqual(stops.map(\.index), [4])
    }

    func testEmptySidesGiveASingleStopAndNeverCrash() {
        XCTAssertEqual(DraftCaretHitTest.stopsBefore(widths: [], originX: 8, available: 50, ellipsis: 8), [Stop(x: 8, index: 0)])
        XCTAssertEqual(DraftCaretHitTest.stopsAfter(widths: [], originX: 8, available: 50, ellipsis: 8, baseIndex: 3), [Stop(x: 8, index: 3)])
        XCTAssertEqual(DraftCaretHitTest.stopsAfter(widths: widths, originX: 0, available: -4, ellipsis: 8, baseIndex: 0).count, 1)
    }

    func testBothSidesTogetherMapAcrossTheCaret() {
        // "ab|cd": before stops end at the caret's left edge, after stops start at its right edge (2 pt caret).
        let before = DraftCaretHitTest.stopsBefore(widths: [10, 10], originX: 8, available: 100, ellipsis: 8)
        let after = DraftCaretHitTest.stopsAfter(widths: [10, 10], originX: 30, available: 100, ellipsis: 8, baseIndex: 2)
        let stops = before + after
        XCTAssertEqual(DraftCaretHitTest.nearestIndex(x: 28, stops: stops), 2)
        XCTAssertEqual(DraftCaretHitTest.nearestIndex(x: 31, stops: stops), 2)
        XCTAssertEqual(DraftCaretHitTest.nearestIndex(x: 41, stops: stops), 3)
        XCTAssertEqual(DraftCaretHitTest.nearestIndex(x: 9, stops: stops), 0)
    }
}
