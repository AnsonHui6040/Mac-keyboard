import RemoteKeyboardCore
import XCTest
@testable import RimeEngine

final class RimePhoneticMethodTests: XCTestCase {
    private func makeMethod(maxCodeLength: Int = 60) throws -> RimeInputMethod {
        let session = try RimeRuntime.start(RimeFixture.compiled("fixture")).makeSession(schema: "fixture_py")
        let config = RimeSchemeConfig(
            schema: "fixture_py", keys: Set("abcdefghijklmnopqrstuvwxyz"),
            maxCodeLength: maxCodeLength, composing: .preedit, probeKey: "a")
        return RimeInputMethod(session: session, config: config, id: .pinyin)
    }

    @discardableResult
    private func type(_ keys: String, into method: inout RimeInputMethod) -> IMEOutput {
        var output = IMEOutput()
        for key in keys { output = method.handle(.key(String(key))) }
        return output
    }

    func testSpaceCommitsBestSentence() throws {
        var method = try makeMethod()
        type("zhongguo", into: &method)
        XCTAssertEqual(method.handle(.space).commit, "中國")
    }

    func testPartialSelectionKeepsTheRestComposing() throws {
        var method = try makeMethod()
        var output = type("zhongguo", into: &method)
        output = method.handle(.selectCandidate(try XCTUnwrap(output.candidates.firstIndex(of: "中"))))
        XCTAssertNil(output.commit)
        XCTAssertEqual(output.candidates.first, "國")
        XCTAssertTrue(output.composing.hasPrefix("中"))
        XCTAssertEqual(method.handle(.selectCandidate(0)).commit, "中國")
    }

    func testInputStopsAtMaxCodeLength() throws {
        var method = try makeMethod(maxCodeLength: 5)
        XCTAssertEqual(type("zhongguo", into: &method).composing.replacingOccurrences(of: " ", with: ""), "zhong")
    }

    func testReturnClearsComposition() throws {
        var method = try makeMethod()
        type("zhong", into: &method)
        XCTAssertEqual(method.handle(.returnKey), IMEOutput())
    }

    func testZhuyinTakesPunctuationKeysAndShowsBopomofo() throws {
        let session = try RimeRuntime.start(RimeFixture.compiled("fixture")).makeSession(schema: "zhuyin")
        var method = RimeInputMethod(session: session, config: .zhuyin, id: .zhuyin)
        let output = type("a83", into: &method)
        XCTAssertEqual(output.composing, "ㄇㄚˇ")
        XCTAssertTrue(output.candidates.contains("馬"))
        XCTAssertNil(method.handle(.key(",")).passThrough)
        XCTAssertEqual(method.handle(.key("！")).passThrough, .character("！"))
    }

    func testZhuyinShowsBopomofoBeforeTheSyllableIsComplete() throws {
        let session = try RimeRuntime.start(RimeFixture.compiled("fixture")).makeSession(schema: "zhuyin")
        var method = RimeInputMethod(session: session, config: .zhuyin, id: .zhuyin)
        XCTAssertEqual(method.handle(.key("r")).composing, "ㄐ")
        method.reset()
        XCTAssertTrue(type("w96r", into: &method).composing.hasSuffix("ㄐ"))
    }

    func testCangjieStopsAtFiveCodes() throws {
        let session = try RimeRuntime.start(RimeFixture.compiled("fixture")).makeSession(schema: "cangjie5")
        var method = RimeInputMethod(session: session, config: .cangjie5, id: .cangjie)
        XCTAssertEqual(type("abcdef", into: &method).composing, CangjieRadicals.display(for: "abcde"))
    }
    func testUppercaseKeyIsTypedAsLowercaseCode() throws {
        let session = try RimeRuntime.start(RimeFixture.compiled("fixture")).makeSession(schema: "quick5")
        var method = RimeInputMethod(session: session, config: .quick5, id: .quick)
        XCTAssertTrue(method.handle(.key("A")).candidates.contains("日"))
    }

    private func makeRealMethod(schema: String, config: RimeSchemeConfig, id: ChineseInputMethodID) throws -> RimeInputMethod {
        RimeInputMethod(session: try RimeRuntime.start(RimeFixture.compiled("fixture")).makeSession(schema: schema),
                        config: config, id: id)
    }

    /// Space on a code whose first candidate takes only part of it, leaving a tail with no candidates: the first
    /// space selects the part, the second commits what was selected and clears the tail.
    private func assertSpaceKeepsSelectedPart(_ keys: String, method: inout RimeInputMethod) {
        let first = type(keys, into: &method)
        let expected = first.candidates.first
        XCTAssertNotNil(expected)
        let afterFirst = method.handle(.space)
        XCTAssertNil(afterFirst.commit)
        XCTAssertTrue(afterFirst.candidates.isEmpty)
        XCTAssertFalse(afterFirst.composing.isEmpty)
        let afterSecond = method.handle(.space)
        XCTAssertEqual(afterSecond.commit, expected)
        XCTAssertEqual(afterSecond.composing, "")
        XCTAssertTrue(afterSecond.candidates.isEmpty)
    }

    func testPinyinSpaceKeepsSelectedPartWhenTheRestHasNoCandidates() throws {
        var method = try makeRealMethod(schema: "pinyin", config: .pinyin, id: .pinyin)
        assertSpaceKeepsSelectedPart("enhpar", method: &method)
    }

    func testJyutpingSpaceKeepsSelectedPartWhenTheRestHasNoCandidates() throws {
        var method = try makeRealMethod(schema: "jyutping", config: .jyutping, id: .jyutping)
        assertSpaceKeepsSelectedPart("mzwipd", method: &method)
    }

    func testSpaceClearsGarbageWithNothingSelected() throws {
        var method = try makeRealMethod(schema: "pinyin", config: .pinyin, id: .pinyin)
        let typed = type("xzxh", into: &method)
        XCTAssertTrue(typed.candidates.isEmpty)
        let output = method.handle(.space)
        XCTAssertNil(output.commit)
        XCTAssertEqual(output.composing, "")
        XCTAssertTrue(output.candidates.isEmpty)
        XCTAssertEqual(method.handle(.space).passThrough, .space)
    }

    /// The rest still has candidates, so space behaves as before: select, not commit, keep composing.
    func testSpaceWithCandidatesLeftStillSelectsPartially() throws {
        var method = try makeRealMethod(schema: "pinyin", config: .pinyin, id: .pinyin)
        var output = type("zhongguo", into: &method)
        output = method.handle(.selectCandidate(try XCTUnwrap(output.candidates.firstIndex(of: "中"))))
        XCTAssertNil(output.commit)
        XCTAssertFalse(output.candidates.isEmpty)
        let space = method.handle(.space)
        XCTAssertEqual(space.commit, "中國")
    }
}
