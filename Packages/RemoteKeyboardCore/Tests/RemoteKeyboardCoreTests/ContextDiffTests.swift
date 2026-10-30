import XCTest
@testable import RemoteKeyboardCore

final class ContextDiffTests: XCTestCase {
    func testAppendProducesText() {
        XCTAssertEqual(ContextDiff.events(before: "你好", after: "你好嗎"), [.text("嗎")])
    }

    func testCorrectionProducesBackspacesThenText() {
        XCTAssertEqual(
            ContextDiff.events(before: "今天天氣", after: "今天的天氣"),
            [.backspace, .backspace, .text("的天氣")])
    }

    func testEmojiCountsAsOneBackspace() {
        XCTAssertEqual(ContextDiff.events(before: "好👨‍👩‍👧", after: "好"), [.backspace])
        XCTAssertEqual(ContextDiff.events(before: "好🙂", after: "好x"), [.backspace, .text("x")])
    }

    func testNoChangeProducesNothing() {
        XCTAssertEqual(ContextDiff.events(before: "abc", after: "abc"), [])
    }

    func testSuffixOnlyChange() {
        XCTAssertEqual(ContextDiff.events(before: "hello world", after: "hello word"), [.backspace, .backspace, .text("d")])
        XCTAssertEqual(ContextDiff.events(before: "abc", after: "ab"), [.backspace])
    }

    func testWholeReplacement() {
        XCTAssertEqual(
            ContextDiff.events(before: "abc", after: "xyz"),
            [.backspace, .backspace, .backspace, .text("xyz")])
    }

    func testEmptyBeforeOrAfter() {
        XCTAssertEqual(ContextDiff.events(before: "", after: "你好"), [.text("你好")])
        XCTAssertEqual(ContextDiff.events(before: "你好", after: ""), [.backspace, .backspace])
        XCTAssertEqual(ContextDiff.events(before: "", after: ""), [])
    }

    func testCJKAndEmojiMix() {
        XCTAssertEqual(
            ContextDiff.events(before: "今天👍很好", after: "今天👍真好吧"),
            [.backspace, .backspace, .text("真好吧")])
        XCTAssertEqual(
            ContextDiff.events(before: "我愛🍎", after: "我愛🍎和🍌"),
            [.text("和🍌")])
    }

    func testCombiningSequenceIsOneCharacter() {
        // "e" + combining acute is one Character, so replacing it is one backspace.
        XCTAssertEqual(ContextDiff.events(before: "cafe\u{301}", after: "caf"), [.backspace])
    }

    func testCountsOnlyLengths() {
        XCTAssertEqual(ContextDiff.counts(before: "今天天氣", after: "今天的天氣").backspaces, 2)
        XCTAssertEqual(ContextDiff.counts(before: "今天天氣", after: "今天的天氣").characters, 3)
    }
}
