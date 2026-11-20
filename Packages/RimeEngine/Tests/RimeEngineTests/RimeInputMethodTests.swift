import XCTest
import RemoteKeyboardCore
@testable import RimeEngine

final class RimeInputMethodTests: XCTestCase {
    private func makeMethod() throws -> RimeInputMethod {
        let session = try RimeRuntime.start(RimeFixture.compiled("fixture")).makeSession(schema: "fixture")
        return RimeInputMethod(session: session)
    }

    func testIdIsQuick() throws {
        XCTAssertEqual(try makeMethod().id, .quick)
    }

    func testKeysShowRadicalsAndCandidates() throws {
        var method = try makeMethod()
        XCTAssertEqual(method.handle(.key("a")).composing, "日")
        let output = method.handle(.key("b"))
        XCTAssertEqual(output.composing, "日月")
        XCTAssertEqual(output.candidates, ["明", "盟"])
        XCTAssertNil(output.commit); XCTAssertNil(output.passThrough)
    }

    func testThirdCodeIsIgnored() throws {
        var method = try makeMethod()
        _ = method.handle(.key("a")); _ = method.handle(.key("b"))
        let output = method.handle(.key("c"))
        XCTAssertEqual(output.composing, "日月")
        XCTAssertEqual(output.candidates, ["明", "盟"])
        XCTAssertNil(output.passThrough)
    }

    func testUnknownCodeShowsNoCandidatesAndSpaceCommitsNothing() throws {
        var method = try makeMethod()
        _ = method.handle(.key("z"))
        let shown = method.handle(.key("z"))
        XCTAssertEqual(shown.candidates, [])
        XCTAssertEqual(shown.composing, "重重")
        let output = method.handle(.space)
        XCTAssertNil(output.commit); XCTAssertNil(output.passThrough)
        XCTAssertEqual(output.composing, "")
        XCTAssertEqual(output.candidates, [])
    }

    func testSpaceCommitsFirstCandidate() throws {
        var method = try makeMethod()
        _ = method.handle(.key("a")); _ = method.handle(.key("b"))
        let output = method.handle(.space)
        XCTAssertEqual(output.commit, "明")
        XCTAssertEqual(output.composing, "")
        XCTAssertEqual(output.candidates, [])
        XCTAssertNil(output.passThrough)
    }

    func testSelectCandidateCommitsThatCandidate() throws {
        var method = try makeMethod()
        _ = method.handle(.key("a")); _ = method.handle(.key("b"))
        XCTAssertEqual(method.handle(.selectCandidate(1)).commit, "盟")
        XCTAssertEqual(method.handle(.key("l")).candidates, ["中"])
        XCTAssertNil(method.handle(.selectCandidate(5)).commit)
    }

    func testSingleCodeCandidates() throws {
        var method = try makeMethod()
        XCTAssertEqual(method.handle(.key("l")).candidates, ["中"])
        XCTAssertEqual(method.handle(.space).commit, "中")
    }

    func testSpaceWithoutCodePassesThrough() throws {
        var method = try makeMethod()
        XCTAssertEqual(method.handle(.space).passThrough, .space)
    }

    func testReturnClearsCodeWithoutCommit() throws {
        var method = try makeMethod()
        _ = method.handle(.key("a")); _ = method.handle(.key("b"))
        let output = method.handle(.returnKey)
        XCTAssertNil(output.commit); XCTAssertNil(output.passThrough)
        XCTAssertEqual(output.composing, "")
        XCTAssertEqual(method.handle(.returnKey).passThrough, .returnKey)
    }

    func testBackspaceRemovesOneCodeThenPassesThrough() throws {
        var method = try makeMethod()
        _ = method.handle(.key("a")); _ = method.handle(.key("b"))
        let one = method.handle(.backspace)
        XCTAssertEqual(one.composing, "日")
        XCTAssertNil(one.passThrough)
        let none = method.handle(.backspace)
        XCTAssertEqual(none.composing, "")
        XCTAssertNil(none.passThrough)
        XCTAssertEqual(method.handle(.backspace).passThrough, .backspace)
    }

    func testShiftTypesOneUppercaseLetter() throws {
        var method = try makeMethod()
        XCTAssertNil(method.handle(.shift).passThrough)
        XCTAssertEqual(method.handle(.key("a")).passThrough, .character("A"))
        // The next key is a code again.
        let output = method.handle(.key("a"))
        XCTAssertNil(output.passThrough)
        XCTAssertEqual(output.composing, "日")
    }

    func testShiftTwiceCancelsShift() throws {
        var method = try makeMethod()
        _ = method.handle(.shift); _ = method.handle(.shift)
        let output = method.handle(.key("a"))
        XCTAssertNil(output.passThrough)
        XCTAssertEqual(output.composing, "日")
    }

    func testShiftKeepsTheCodeBeingComposed() throws {
        var method = try makeMethod()
        _ = method.handle(.key("a"))
        _ = method.handle(.shift)
        let typed = method.handle(.key("b"))
        XCTAssertEqual(typed.passThrough, .character("B"))
        XCTAssertEqual(typed.composing, "日")
    }

    func testOutputReportsShiftState() throws {
        var method = try makeMethod()
        XCTAssertFalse(method.handle(.key("a")).shift)
        XCTAssertTrue(method.handle(.shift).shift)
        XCTAssertFalse(method.handle(.shift).shift)
        XCTAssertTrue(method.handle(.shift).shift)
        // The uppercase letter uses the Shift up.
        XCTAssertFalse(method.handle(.key("b")).shift)
    }

    func testShiftIsOffAfterCommitClearAndReset() throws {
        var method = try makeMethod()
        _ = method.handle(.key("a")); _ = method.handle(.key("b")); _ = method.handle(.shift)
        let committed = method.handle(.space)
        XCTAssertEqual(committed.commit, "明")
        XCTAssertFalse(committed.shift)
        XCTAssertEqual(method.handle(.key("a")).passThrough, nil)

        _ = method.handle(.shift)
        XCTAssertFalse(method.handle(.returnKey).shift)
        _ = method.handle(.key("l")); _ = method.handle(.shift)
        XCTAssertFalse(method.handle(.selectCandidate(0)).shift)
        _ = method.handle(.shift)
        XCTAssertFalse(method.handle(.clear).shift)
        _ = method.handle(.shift)
        method.reset()
        XCTAssertFalse(method.handle(.backspace).shift)
    }

    func testNonLetterKeyPassesThrough() throws {
        var method = try makeMethod()
        XCTAssertEqual(method.handle(.key("1")).passThrough, .character("1"))
        XCTAssertEqual(method.handle(.key("，")).passThrough, .character("，"))
    }

    func testClearAndResetDropTheCode() throws {
        var method = try makeMethod()
        _ = method.handle(.key("a"))
        XCTAssertEqual(method.handle(.clear).composing, "")
        _ = method.handle(.key("a"))
        method.reset()
        XCTAssertEqual(method.handle(.key("l")).composing, "中")
    }

    func testNonLetterKeysPassThroughWithoutReachingRime() throws {
        var method = try makeMethod()
        _ = method.handle(.key("a"))
        XCTAssertEqual(method.handle(.key("，")).passThrough, .character("，"))
        XCTAssertEqual(method.handle(.key("😀")).passThrough, .character("😀"))
        XCTAssertEqual(method.handle(.key("1")).passThrough, .character("1"))
        XCTAssertEqual(method.handle(.key("b")).candidates, ["明", "盟"])
    }

    func testBackspaceRemovesExactlyOneCode() throws {
        var method = try makeMethod()
        _ = method.handle(.key("z")); _ = method.handle(.key("z"))
        XCTAssertEqual(method.handle(.backspace).composing, "重")
    }

    func testFailedSelectionKeepsCompositionAndShift() throws {
        var method = try makeMethod()
        _ = method.handle(.key("a")); _ = method.handle(.key("b")); _ = method.handle(.shift)
        let output = method.commit(index: 99)
        XCTAssertNil(output.commit)
        XCTAssertEqual(output.composing, "日月")
        XCTAssertEqual(output.candidates, ["明", "盟"])
        XCTAssertTrue(output.shift)
        XCTAssertEqual(method.handle(.selectCandidate(0)).commit, "明")
    }
}
