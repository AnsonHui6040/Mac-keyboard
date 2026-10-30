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

    func testTextAroundTheCursor() {
        var draft = DraftBuffer()
        _ = draft.insert("香港你好")
        draft.moveLeft(); draft.moveLeft()
        XCTAssertEqual(draft.textBeforeCursor, "香港")
        XCTAssertEqual(draft.textAfterCursor, "你好")
    }
}
