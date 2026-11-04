import XCTest
@testable import RemoteKeyboardCore

final class UnicodeChunkerTests: XCTestCase {
    func testChunkerNeverSplitsGraphemeCluster() {
        let family = "👨‍👩‍👧‍👦"                       // 11 UTF-16 units
        let chunks = UnicodeChunker.chunks(family + family, maxUTF16: 20)
        XCTAssertEqual(chunks, [family, family])
    }

    func testChunkerKeepsCombiningAccent() { XCTAssertEqual(UnicodeChunker.chunks("cafe\u{301}", maxUTF16: 4), ["caf", "e\u{301}"]) }

    func testChunkerJoinsBackToOriginal() {
        let s = "繁體中文，標點：「你好嗎？」👨‍👩‍👧‍👦 café"
        XCTAssertEqual(UnicodeChunker.chunks(s).joined(), s)
        XCTAssertTrue(UnicodeChunker.chunks(s).allSatisfy { $0.utf16.count <= 20 })
    }

    func testEmptyStringHasNoChunks() { XCTAssertEqual(UnicodeChunker.chunks(""), []) }
    func testShortStringIsOneChunk() { XCTAssertEqual(UnicodeChunker.chunks("Hello"), ["Hello"]) }
    func testSingleOversizedCharacterIsSplitOnScalarBoundaries() {
        let family = "👨‍👩‍👧‍👦"
        let chunks = UnicodeChunker.chunks("a" + family + "b", maxUTF16: 4)
        XCTAssertEqual(chunks.first, "a")
        XCTAssertEqual(chunks.last, "b")
        XCTAssertEqual(chunks.joined(), "a" + family + "b")
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 4 })
        XCTAssertEqual(chunks.dropFirst().dropLast().map { $0.unicodeScalars.count }, [2, 2, 2, 1], "emoji and joiner pairs, never half a surrogate pair")
    }
    func testBaseLetterWith30CombiningMarksIsSplitWithinTheLimit() {
        let text = "e" + String(repeating: "\u{301}", count: 30)
        XCTAssertEqual(text.count, 1, "one Character")
        let chunks = UnicodeChunker.chunks(text)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= UnicodeChunker.defaultMaxUTF16 })
    }
    func testOversizedCharacterBetweenOrdinaryTextKeepsTheRestIntact() {
        let long = "e" + String(repeating: "\u{301}", count: 30)
        let text = "hello " + long + " world"
        let chunks = UnicodeChunker.chunks(text)
        XCTAssertEqual(chunks.joined(), text)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 20 })
    }
    func testEmojiThatFitsIsStillOneUnbrokenChunk() {
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(UnicodeChunker.chunks(family), [family])
        XCTAssertEqual(UnicodeChunker.chunks("a" + family + "b", maxUTF16: 20), ["a" + family + "b"])
    }
    func testExactlyAtLimitStaysTogether() {
        XCTAssertEqual(UnicodeChunker.chunks("abcd", maxUTF16: 4), ["abcd"])
        XCTAssertEqual(UnicodeChunker.chunks("abcde", maxUTF16: 4), ["abcd", "e"])
    }
    func testDefaultMaxIsTwenty() { XCTAssertEqual(UnicodeChunker.defaultMaxUTF16, 20) }
}
