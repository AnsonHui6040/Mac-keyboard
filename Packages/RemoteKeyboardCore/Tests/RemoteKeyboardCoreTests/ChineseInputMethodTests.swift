import XCTest
@testable import RemoteKeyboardCore

final class ChineseInputMethodTests: XCTestCase {
    func testEmptyOutputHasNothingToDo() {
        let output = IMEOutput()
        XCTAssertNil(output.commit)
        XCTAssertEqual(output.composing, "")
        XCTAssertEqual(output.candidates, [])
        XCTAssertNil(output.passThrough)
    }

    func testMethodIdsAreStable() {
        XCTAssertEqual(ChineseInputMethodID.allCases, [.handwriting, .quick])
        XCTAssertEqual(ChineseInputMethodID.handwriting.rawValue, "handwriting")
        XCTAssertEqual(ChineseInputMethodID.quick.rawValue, "quick")
    }

    func testHanFilterKeepsOnlyCandidatesMadeOfHanCharacters() {
        XCTAssertTrue(HanCharacters.isAllHan("二"))
        XCTAssertTrue(HanCharacters.isAllHan("香港"))
        XCTAssertTrue(HanCharacters.isAllHan("𠀀"))  // CJK Extension B
        XCTAssertFalse(HanCharacters.isAllHan("="))
        XCTAssertFalse(HanCharacters.isAllHan("+"))
        XCTAssertFalse(HanCharacters.isAllHan("a"))
        XCTAssertFalse(HanCharacters.isAllHan("8"))
        XCTAssertFalse(HanCharacters.isAllHan("二="))
        XCTAssertFalse(HanCharacters.isAllHan("あ"))
        XCTAssertFalse(HanCharacters.isAllHan("，"))
        XCTAssertFalse(HanCharacters.isAllHan(""))
        XCTAssertEqual(HanCharacters.filter(["=", "二", "+", "三a", "三", "二"]), ["二", "三"])
    }
}
