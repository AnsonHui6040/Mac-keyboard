import RemoteKeyboardCore
import XCTest
@testable import RimeEngine

/// Initial-only abbreviations (speller/algebra abbrev) for pinyin, jyutping and zhuyin, on the real schemes.
final class RimeInitialAbbrevTests: XCTestCase {
    private func makeMethod(_ schema: String, _ config: RimeSchemeConfig, _ id: ChineseInputMethodID) throws -> RimeInputMethod {
        RimeInputMethod(session: try RimeRuntime.start(RimeFixture.compiled("fixture")).makeSession(schema: schema),
                        config: config, id: id)
    }

    private func type(_ keys: String, into method: inout RimeInputMethod) -> IMEOutput {
        var output = IMEOutput()
        for key in keys { output = method.handle(.key(String(key))) }
        return output
    }

    private func output(_ schema: String, _ config: RimeSchemeConfig, _ id: ChineseInputMethodID, _ keys: String) throws -> IMEOutput {
        var method = try makeMethod(schema, config, id)
        return type(keys, into: &method)
    }

    func testPinyinSingleInitialHasCandidates() throws {
        let out = try output("pinyin", .pinyin, .pinyin, "s")
        XCTAssertFalse(out.candidates.isEmpty)
        XCTAssertTrue(out.candidates.contains("是"))
    }

    func testPinyinDigraphInitialHasCandidates() throws {
        let out = try output("pinyin", .pinyin, .pinyin, "zh")
        XCTAssertFalse(out.candidates.isEmpty)
        XCTAssertTrue(out.candidates.contains("中"))
    }

    func testPinyinTwoInitialsGiveAWord() throws {
        let out = try output("pinyin", .pinyin, .pinyin, "nh")
        XCTAssertTrue(out.candidates.contains("你好"), "candidates: \(out.candidates)")
    }

    func testJyutpingSingleInitialHasCandidates() throws {
        XCTAssertFalse(try output("jyutping", .jyutping, .jyutping, "n").candidates.isEmpty)
    }

    /// "ng" is also a full syllable (唔), and librime lets that exact spelling shadow the abbreviation of "ngo", so a
    /// lone "ng" does not list 我. The ng initial does work once a second initial follows.
    func testJyutpingNgInitialWorksInAWordButLoneNgStaysTheSyllable() throws {
        XCTAssertEqual(try output("jyutping", .jyutping, .jyutping, "ng").candidates.first, "唔")
        let word = try output("jyutping", .jyutping, .jyutping, "ngd")
        XCTAssertTrue(word.candidates.contains("我哋"), "candidates: \(word.candidates)")
    }

    func testJyutpingGwKwInitialsHaveCandidates() throws {
        XCTAssertTrue(try output("jyutping", .jyutping, .jyutping, "gw").candidates.contains("國"))
        XCTAssertFalse(try output("jyutping", .jyutping, .jyutping, "kw").candidates.isEmpty)
    }

    func testJyutpingTwoInitialsGiveAWord() throws {
        let out = try output("jyutping", .jyutping, .jyutping, "nh")
        XCTAssertTrue(out.candidates.contains("你好"), "candidates: \(out.candidates)")
    }

    /// ㄌ (key x) alone was empty before; the key for ㄓ (5) already had a syllable.
    func testZhuyinInitialOnlyHasCandidates() throws {
        let out = try output("zhuyin", .zhuyin, .zhuyin, "x")
        XCTAssertEqual(out.composing, "ㄌ")
        XCTAssertFalse(out.candidates.isEmpty)
    }

    func testZhuyinZhInitialShowsBopomofoAndCandidates() throws {
        let out = try output("zhuyin", .zhuyin, .zhuyin, "5")
        XCTAssertEqual(out.composing, "ㄓ")
        XCTAssertFalse(out.candidates.isEmpty)
    }

    /// First candidates of full codes, recorded before the abbrev rules were added.
    func testFullCodesKeepTheirFirstCandidate() throws {
        let expected: [(String, RimeSchemeConfig, ChineseInputMethodID, String, String)] = [
            ("pinyin", .pinyin, .pinyin, "zhongguo", "中國"),
            ("pinyin", .pinyin, .pinyin, "shi", "是"),
            ("pinyin", .pinyin, .pinyin, "ni", "你"),
            ("pinyin", .pinyin, .pinyin, "nihao", "你好"),
            ("pinyin", .pinyin, .pinyin, "wo", "我"),
            ("jyutping", .jyutping, .jyutping, "ngo", "我"),
            ("jyutping", .jyutping, .jyutping, "nei", "你"),
            ("jyutping", .jyutping, .jyutping, "hou", "好"),
            ("jyutping", .jyutping, .jyutping, "ng", "唔"),
            ("zhuyin", .zhuyin, .zhuyin, "5j/", "中"),
            ("zhuyin", .zhuyin, .zhuyin, "a83", "馬"),
            ("zhuyin", .zhuyin, .zhuyin, "su3", "你"),
            ("zhuyin", .zhuyin, .zhuyin, "cl3", "好"),
            ("zhuyin", .zhuyin, .zhuyin, "2k7", "的"),
        ]
        for (schema, config, id, keys, first) in expected {
            let out = try output(schema, config, id, keys)
            XCTAssertEqual(out.candidates.first, first, "\(schema) \(keys)")
        }
    }
}
