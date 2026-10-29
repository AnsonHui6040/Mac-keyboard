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
    func testSingleOversizedCharacterGetsOwnChunk() {
        let family = "👨‍👩‍👧‍👦"
        XCTAssertEqual(UnicodeChunker.chunks("a" + family + "b", maxUTF16: 4), ["a", family, "b"])
    }
    func testExactlyAtLimitStaysTogether() {
        XCTAssertEqual(UnicodeChunker.chunks("abcd", maxUTF16: 4), ["abcd"])
        XCTAssertEqual(UnicodeChunker.chunks("abcde", maxUTF16: 4), ["abcd", "e"])
    }
    func testDefaultMaxIsTwenty() { XCTAssertEqual(UnicodeChunker.defaultMaxUTF16, 20) }
}
