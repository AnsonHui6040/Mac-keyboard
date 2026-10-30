import XCTest
@testable import RemoteKeyboardCore

final class HandwritingInputMethodTests: XCTestCase {
    private func method(with candidates: [String]) -> HandwritingInputMethod {
        var method = HandwritingInputMethod()
        _ = method.handle(.recognized(candidates))
        return method
    }

    func testIdIsHandwriting() {
        XCTAssertEqual(HandwritingInputMethod().id, .handwriting)
    }

    func testRecognizedFillsCandidatesMaxNine() {
        var method = HandwritingInputMethod()
        let list = (0..<12).map { String(UnicodeScalar(0x4E00 + $0)!) }
        let output = method.handle(.recognized(list))
        XCTAssertEqual(output.candidates.count, 9)
        XCTAssertEqual(output.candidates, Array(list.prefix(9)))
        XCTAssertNil(output.commit); XCTAssertNil(output.passThrough)
        XCTAssertEqual(output.composing, "")
    }

    func testRecognizedDropsNonHanCandidates() {
        var method = HandwritingInputMethod()
        // The device answered "=" for 二 and "+" for 十.
        XCTAssertEqual(method.handle(.recognized(["=", "二", "三", "+"])).candidates, ["二", "三"])
        XCTAssertEqual(method.handle(.recognized(["+", "十", "千"])).candidates, ["十", "千"])
    }

    func testRecognizedFiltersBeforeCappingAtNine() {
        var method = HandwritingInputMethod()
        let han = (0..<9).map { String(UnicodeScalar(0x4E00 + $0)!) }
        let output = method.handle(.recognized(["=", "+"] + han + ["丁"]))
        XCTAssertEqual(output.candidates, han)
    }

    func testRecognizedReplacesEarlierCandidates() {
        var method = HandwritingInputMethod()
        _ = method.handle(.recognized(["香", "秤"]))
        XCTAssertEqual(method.handle(.recognized(["港"])).candidates, ["港"])
    }

    func testSelectCandidateCommitsAndClears() {
        var method = method(with: ["香", "秤", "港"])
        let output = method.handle(.selectCandidate(1))
        XCTAssertEqual(output.commit, "秤")
        XCTAssertEqual(output.candidates, [])
        XCTAssertNil(output.passThrough)
        XCTAssertEqual(method.handle(.space).passThrough, .space, "the ink is gone, so space is a plain space again")
    }

    func testSelectCandidateOutOfRangeDoesNothing() {
        var method = method(with: ["香"])
        let output = method.handle(.selectCandidate(3))
        XCTAssertNil(output.commit)
        XCTAssertEqual(output.candidates, ["香"])
        XCTAssertEqual(method.handle(.selectCandidate(-1)).candidates, ["香"])
    }

    func testSpaceCommitsFirstCandidate() {
        var method = method(with: ["香", "秤"])
        let output = method.handle(.space)
        XCTAssertEqual(output.commit, "香")
        XCTAssertEqual(output.candidates, [])
        XCTAssertNil(output.passThrough)
    }

    func testSpaceWithoutCandidatesPassesThrough() {
        var method = HandwritingInputMethod()
        let output = method.handle(.space)
        XCTAssertEqual(output.passThrough, .space)
        XCTAssertNil(output.commit)
    }

    func testBackspaceClearsCandidatesBeforeDeleting() {
        var method = method(with: ["香", "秤"])
        let first = method.handle(.backspace)
        XCTAssertEqual(first.candidates, [])
        XCTAssertNil(first.passThrough)
        XCTAssertNil(first.commit)
        XCTAssertEqual(method.handle(.backspace).passThrough, .backspace)
    }

    func testInkWithoutCandidatesIsClearedBeforeAnyKeyPassesThrough() {
        // The ink was recognised as nothing Han (for example "="): the candidates are empty but the ink is there.
        for input in [IMEInput.backspace, .space, .returnKey] {
            var method = method(with: ["=", "+"])
            let first = method.handle(input)
            XCTAssertNil(first.passThrough, "\(input) first clears the ink")
            XCTAssertNil(first.commit)
            XCTAssertEqual(first.candidates, [])
            XCTAssertNotNil(method.handle(input).passThrough, "\(input) then behaves as a normal key")
        }
    }

    func testReturnWithCandidatesClearsWithoutCommitting() {
        var method = method(with: ["香"])
        let output = method.handle(.returnKey)
        XCTAssertNil(output.commit); XCTAssertNil(output.passThrough)
        XCTAssertEqual(output.candidates, [])
        XCTAssertEqual(method.handle(.returnKey).passThrough, .returnKey)
    }

    func testReturnWithoutInkPassesThrough() {
        var method = HandwritingInputMethod()
        XCTAssertEqual(method.handle(.returnKey).passThrough, .returnKey)
    }

    func testClearDropsInkAndCandidates() {
        var method = method(with: ["香"])
        let output = method.handle(.clear)
        XCTAssertEqual(output, IMEOutput())
        XCTAssertEqual(method.handle(.backspace).passThrough, .backspace)
    }

    func testResetDropsInkAndCandidates() {
        var method = method(with: ["香"])
        method.reset()
        XCTAssertEqual(method.handle(.space).passThrough, .space)
    }

    func testLetterKeysAndShiftAreNotHandled() {
        var method = HandwritingInputMethod()
        XCTAssertEqual(method.handle(.key("a")).passThrough, .character("a"))
        XCTAssertEqual(method.handle(.shift), IMEOutput())
    }
}
