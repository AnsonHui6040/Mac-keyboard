import XCTest
@testable import ImeData

final class MandarinTests: XCTestCase {
    let data = McBopomofoData.parse(
        base: """
        中 ㄓㄨㄥ zhong 5j/ big5
        中 ㄓㄨㄥˋ zhong4 5j/4 big5
        國 ㄍㄨㄛˊ guo2 eji6 big5
        女 ㄋㄩˇ nv3 sm3 big5
        ㄝ ㄝ e , big5
        """,
        mappings: "中國 ㄓㄨㄥ ㄍㄨㄛˊ\n中國人 ㄓㄨㄥ ㄍㄨㄛˊ ㄖㄣˊ\n人中 ㄖㄣˊ ㄓㄨㄥ\n",
        occurrences: "中 100\n國 80\n中國 30\n人中 5\n",
        exclusions: "# comment line\n中\t中國\n",
        heterophony: ["中 ㄓㄨㄥ\n", "", ""])

    func testKeysForSyllables() {
        XCTAssertEqual(BopomofoKeys.keys(for: "ㄓㄨㄥ"), "5j/")
        XCTAssertEqual(BopomofoKeys.keys(for: "ㄌㄩㄝˋ"), "xm,4")
        XCTAssertEqual(BopomofoKeys.keys(for: "ㄇㄚ˙"), "a87")
        XCTAssertNil(BopomofoKeys.keys(for: "ㄓx"))
    }

    func testZhuyinAndPinyinEntries() {
        let zhuyin = MandarinDicts.zhuyin(data)
        XCTAssertEqual(zhuyin.entries.map { "\($0.code)|\($0.text)|\($0.weight!)" },
                       ["5j/|中|70", "5j/ eji6|中國|81", "5j/4|中|6", "bp6 5j/|人中|14", "eji6|國|80", "sm3|女|1"])
        XCTAssertEqual(zhuyin.dropped, 0)
        XCTAssertEqual(zhuyin.keyMismatches, 0)
        let pinyin = MandarinDicts.pinyin(data)
        XCTAssertEqual(pinyin.entries.map { "\($0.code)|\($0.text)|\($0.weight!)" },
                       ["guo|國|80", "nv|女|1", "zhong|中|70", "zhong guo|中國|81"])
        XCTAssertEqual(pinyin.dropped, 1)  // 人中: ㄖㄣˊ has no pinyin in BPMFBase
    }

    func testHeterophonyHalvesSecondReading() {
        let data = McBopomofoData.parse(
            base: "行 ㄒㄧㄥˊ xing2 vu/6 big5\n行 ㄏㄤˊ hang2 c;6 big5\n行 ㄏㄤˋ hang4 c;4 big5\n",
            mappings: "", occurrences: "行 40\n", exclusions: "",
            heterophony: ["行 ㄒㄧㄥˊ\n", "行 ㄏㄤˊ\n", ""])
        XCTAssertEqual(MandarinDicts.zhuyin(data).entries.map { "\($0.code)|\($0.weight!)" },
                       ["c;4|6", "c;6|8", "vu/6|40"])
    }

    func testKeyTableLengths() {
        XCTAssertEqual(BopomofoKeys.keys.count, BopomofoKeys.symbols.count)
        XCTAssertEqual(BopomofoKeys.keys.count, 41)
    }

    func testKeyMismatchIsCounted() {
        let data = McBopomofoData.parse(base: "公 ㄍㄨㄥ˙ gong5 ej/5 big5\n", mappings: "", occurrences: "",
                                        exclusions: "", heterophony: ["", "", ""])
        let output = MandarinDicts.zhuyin(data)
        XCTAssertEqual(output.keyMismatches, 1)
        XCTAssertEqual(output.entries.map(\.code), ["ej/7"])  // code comes from the bopomofo column
        XCTAssertEqual(output.mismatches, [KeyMismatch(line: 1, zhuyin: "ㄍㄨㄥ˙", given: "ej/5")])
    }
}
