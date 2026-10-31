#if DEBUG
import XCTest
@testable import RemoteKeyboardCore

final class MeasureLongTextTests: XCTestCase {
    func testTheLongTextIs3000CharactersAnd6000Bytes() {
        XCTAssertEqual(MeasureLongText.text.count, 3_000)
        XCTAssertEqual(MeasureLongText.text.utf8.count, 6_000)
        XCTAssertEqual(MeasureLongText.utf8Length, 6_000)
    }

    func testTheHashIsSha256OfTheUtf8Bytes() {
        XCTAssertEqual(MeasureLongText.sha256Hex.count, 64)
        XCTAssertTrue(MeasureLongText.sha256Hex.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        XCTAssertEqual(MeasureLongText.sha256Hex, MeasureLongText.sha256Hex(of: MeasureLongText.text))
        // A known vector: SHA-256("abc").
        XCTAssertEqual(
            MeasureLongText.sha256Hex(of: "abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testCheckAcceptsTheExactTextOnly() {
        XCTAssertEqual(MeasureLongText.check(MeasureLongText.text), .match)
        XCTAssertEqual(MeasureLongText.check(String(MeasureLongText.text.dropLast())), .mismatch)
        XCTAssertEqual(MeasureLongText.check(MeasureLongText.text + "一"), .mismatch)
        // Same length, one character different: the length matches and the hash does not.
        var changed = MeasureLongText.text
        changed.replaceSubrange(changed.startIndex...changed.startIndex, with: "二")
        XCTAssertEqual(changed.utf8.count, MeasureLongText.utf8Length)
        XCTAssertEqual(MeasureLongText.check(changed), .mismatch)
        XCTAssertEqual(MeasureLongText.check(""), .mismatch)
    }

    func testOnlyLongTextsAreChecked() {
        XCTAssertEqual(MeasureLongText.candidateMinimumUtf8, 1_000)
        XCTAssertFalse(MeasureLongText.isCandidate("hello"))
        XCTAssertFalse(MeasureLongText.isCandidate(String(repeating: "x", count: 999)))
        XCTAssertTrue(MeasureLongText.isCandidate(String(repeating: "x", count: 1_000)), "a damaged copy is reported, not skipped")
        XCTAssertTrue(MeasureLongText.isCandidate(MeasureLongText.text))
    }
}
#endif
