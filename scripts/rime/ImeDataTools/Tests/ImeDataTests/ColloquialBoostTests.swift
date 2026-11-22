import XCTest
@testable import ImeData

final class ColloquialBoostTests: XCTestCase {
    private func entry(_ text: String, _ code: String, _ weight: Int) -> DictEntry {
        DictEntry(text: text, code: code, weight: weight)
    }

    private func weights(_ entries: [DictEntry]) -> [String: Int] {
        var result: [String: Int] = [:]
        for e in entries { result[e.text + "|" + e.code] = e.weight }
        return result
    }

    func testParseListSkipsCommentsAndBlankLines() {
        let list = ColloquialBoost.parse("# header\n\n你好\n  謝謝  \n# 註解\r\n不客氣\r\n")
        XCTAssertEqual(list, ["你好", "謝謝", "不客氣"])
    }

    func testListWordGoesAboveEveryNonListWordWithTheSameInitialKey() throws {
        let entries = [entry("女孩", "nv hai", 2832), entry("年後", "nian hou", 900),
                       entry("你好", "ni hao", 327), entry("你", "ni", 5000), entry("你好嗎", "ni hao ma", 4000)]
        let result = try ColloquialBoost.apply(to: entries, list: ["你好"])
        XCTAssertEqual(weights(result.entries)["你好|ni hao"], 2833)
        XCTAssertEqual(result.boosted, 1)
        // Others are untouched; single characters and other syllable counts do not count.
        XCTAssertEqual(weights(result.entries)["女孩|nv hai"], 2832)
        XCTAssertEqual(weights(result.entries)["你|ni"], 5000)
        XCTAssertEqual(result.entries.first(where: { $0.text == "你好" })?.weight, 2833)
    }

    func testWeightsNeverGoDown() throws {
        let entries = [entry("女孩", "nv hai", 100), entry("你好", "ni hao", 327)]
        let result = try ColloquialBoost.apply(to: entries, list: ["你好"])
        XCTAssertEqual(weights(result.entries)["你好|ni hao"], 327)
        XCTAssertEqual(result.boosted, 0)
    }

    func testOtherListWordsDoNotRaiseTheBar() throws {
        // 你好 and 年後 share the key "nh"; 年後 is on the list, so it is not a non-list competitor.
        let entries = [entry("你好", "ni hao", 10), entry("年後", "nian hou", 2000), entry("女孩", "nv hai", 50)]
        let result = try ColloquialBoost.apply(to: entries, list: ["你好", "年後"])
        let w = weights(result.entries)
        XCTAssertEqual(w["年後|nian hou"], 2000)   // already above the non-list max 50
        XCTAssertEqual(w["你好|ni hao"], 2001)     // earlier in the list ranks above the later one
    }

    func testCollidingListWordsKeepListOrder() throws {
        let entries = [entry("女孩", "nv hai", 500), entry("你好", "ni hao", 10), entry("年後", "nian hou", 20),
                       entry("男孩", "nan hai", 400)]
        let result = try ColloquialBoost.apply(to: entries, list: ["你好", "年後"])
        let w = weights(result.entries)
        XCTAssertEqual(w["年後|nian hou"], 501)
        XCTAssertEqual(w["你好|ni hao"], 502)
        XCTAssertEqual(result.boosted, 2)
    }

    func testEveryReadingIsHandled() throws {
        let entries = [entry("行了", "xing le", 5), entry("行了", "hang le", 5), entry("喜歡", "xi huan", 9),
                       entry("海龍", "hai long", 700), entry("學歷", "xue li", 300)]
        let result = try ColloquialBoost.apply(to: entries, list: ["行了"])
        let w = weights(result.entries)
        XCTAssertEqual(w["行了|xing le"], 301)  // key xl: 學歷 300
        XCTAssertEqual(w["行了|hang le"], 701)  // key hl: 海龍 700
    }

    func testSyllableCountSeparatesGroups() throws {
        let entries = [entry("你好", "ni hao", 1), entry("你好嗎", "ni hao ma", 9999)]
        let result = try ColloquialBoost.apply(to: entries, list: ["你好"])
        XCTAssertEqual(weights(result.entries)["你好|ni hao"], 1)
    }

    func testZhuyinKeysUseTheFirstKeyOfEachSyllable() throws {
        let entries = [entry("你好", "su3 cl3", 327), entry("男孩", "sj6 cl6", 2000), entry("好", "cl3", 8000)]
        let result = try ColloquialBoost.apply(to: entries, list: ["你好"], style: .zhuyin)
        XCTAssertEqual(weights(result.entries)["你好|su3 cl3"], 2001)
    }

    func testMissingWordThrowsAndNamesIt() {
        let entries = [entry("你好", "ni hao", 327)]
        XCTAssertThrowsError(try ColloquialBoost.apply(to: entries, list: ["你好", "不存在", "也沒有"])) { error in
            guard let missing = error as? ColloquialBoost.MissingWords else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(missing.words, ["不存在", "也沒有"])
            XCTAssertTrue("\(missing)".contains("不存在"))
        }
    }

    func testResultIsSortedLikeAnyDictionary() throws {
        let entries = [entry("女孩", "nv hai", 2832), entry("你好", "ni hao", 327), entry("年後", "nian hou", 900)]
        let result = try ColloquialBoost.apply(to: entries, list: ["你好"])
        XCTAssertEqual(result.entries.map(\.code), ["nian hou", "ni hao", "nv hai"].sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
        XCTAssertEqual(result.entries.map(\.text), ["你好", "年後", "女孩"])
    }

    /// 應該 = ㄧㄥ ㄍㄞ: ㄧ (key u) is not an initial, so the abbreviation "ue" can never be typed for it; the syllable
    /// is keyed by its full code without the tone key, and 一個 (ㄧ ㄍㄜ˙) does not compete with it for "ue".
    func testZhuyinSyllableWithoutInitialUsesFullSyllableKey() throws {
        let entries = [entry("應該", "u/6 ej4", 5), entry("一個", "u ek7", 9000), entry("女孩", "sm3 c96", 100), entry("你好", "su3 cl3", 1)]
        let result = try ColloquialBoost.apply(to: entries, list: ["應該", "你好"], style: .zhuyin)
        let w = weights(result.entries)
        XCTAssertEqual(w["應該|u/6 ej4"], 5)          // 一個 shares the first key u but not the full syllable
        XCTAssertEqual(w["你好|su3 cl3"], 101)
        // ㄨㄛ (ji) likewise
        let more = try ColloquialBoost.apply(to: [entry("我們", "ji3 a/6", 3), entry("文爺", "jp3 a/6", 900)], list: ["我們"], style: .zhuyin)
        XCTAssertEqual(weights(more.entries)["我們|ji3 a/6"], 3)
    }

    func testPinyinStyleStillUsesFirstLetterOfEveryLetterSyllable() throws {
        let entries = [entry("應該", "ying gai", 5), entry("一個", "yi ge", 9000)]
        let result = try ColloquialBoost.apply(to: entries, list: ["應該"])
        XCTAssertEqual(weights(result.entries)["應該|ying gai"], 9001)
    }

    func testSingleCharacterListWordThrows() {
        XCTAssertThrowsError(try ColloquialBoost.apply(to: [entry("你", "ni", 1)], list: ["你"])) { error in
            XCTAssertTrue("\(error)".contains("你"))
        }
    }

    func testDuplicateListWordThrows() {
        let entries = [entry("你好", "ni hao", 1)]
        XCTAssertThrowsError(try ColloquialBoost.apply(to: entries, list: ["你好", "你好"])) { error in
            XCTAssertTrue("\(error)".contains("你好"))
        }
    }

    func testMandarinDictsAppliesTheListToBoth() throws {
        let data = McBopomofoData.parse(
            base: """
            你 ㄋㄧˇ ni3 su3 big5
            好 ㄏㄠˇ hao3 cl3 big5
            女 ㄋㄩˇ nv3 sm3 big5
            孩 ㄏㄞˊ hai2 c96 big5
            """,
            mappings: "你好 ㄋㄧˇ ㄏㄠˇ\n女孩 ㄋㄩˇ ㄏㄞˊ\n", occurrences: "你 10\n好 10\n女 10\n孩 10\n你好 3\n女孩 50\n",
            exclusions: "", heterophony: ["", "", ""])
        let plainPinyin = try MandarinDicts.pinyin(data)
        let plainZhuyin = try MandarinDicts.zhuyin(data)
        let pinyin = try MandarinDicts.pinyin(data, boost: ["你好"])
        let zhuyin = try MandarinDicts.zhuyin(data, boost: ["你好"])
        XCTAssertLessThan(weights(plainPinyin.entries)["你好|ni hao"]!, weights(plainPinyin.entries)["女孩|nv hai"]!)
        XCTAssertGreaterThan(weights(pinyin.entries)["你好|ni hao"]!, weights(pinyin.entries)["女孩|nv hai"]!)
        XCTAssertGreaterThan(weights(zhuyin.entries)["你好|su3 cl3"]!, weights(zhuyin.entries)["女孩|sm3 c96"]!)
        XCTAssertEqual(pinyin.boosted, 1)
        XCTAssertEqual(zhuyin.boosted, 1)
        XCTAssertEqual(plainZhuyin.boosted, 0)
        XCTAssertThrowsError(try MandarinDicts.pinyin(data, boost: ["不存在"]))
    }
}
