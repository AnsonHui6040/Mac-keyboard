import XCTest
@testable import ImeData

final class CangjieTests: XCTestCase {
    // char simp zh big5 hkscs zhuyin kanji hira kata punct symbol cj3 cj5 short order
    let table = """
    # comment

    日 日 1 1 0 0 1 0 0 0 0 a a NA 9000
    曰 曰 1 1 0 0 0 0 0 0 0 a a NA 8000
    嘅 嘅 1 0 1 0 1 0 0 0 0 rhpu rhpu NA 0
    嘅 嘅 1 0 1 0 1 0 0 0 0 raiu raiu NA 0
    啱 啱 1 0 1 0 0 0 0 0 0 rmbu rmbu NA 0
    呑 呑 1 1 0 0 0 0 0 0 0 rhpu NA NA 0
    ° NA 0 0 0 0 0 0 0 0 1 yyycg yyycg NA 0
    冇 冇 1 1 0 0 1 0 0 0 0 kb kb,xkb NA 14449
    """
    let frequency = ["嘅": 900, "啱": 50]

    func testCangjie5PutsBig5FirstThenHKSCSByFrequency() throws {
        let entries = CangjieDicts.cangjie5(try CangjieTable.parse(table), frequency: frequency)
        XCTAssertEqual(entries.map { "\($0.code) \($0.text)" },
                       ["a 日", "a 曰", "kb 冇", "raiu 嘅", "rhpu 呑", "rhpu 嘅", "rmbu 啱", "xkb 冇"])
    }
    func testQuick5TakesFirstAndLastLetterAndDropsRepeats() throws {
        let entries = CangjieDicts.quick5(try CangjieTable.parse(table), frequency: frequency)
        XCTAssertEqual(entries.map { "\($0.code) \($0.text)" },
                       ["a 日", "a 曰", "kb 冇", "ru 呑", "ru 嘅", "ru 啱", "xb 冇"])
    }
    func testRejectsLineWithWrongColumnCount() {
        XCTAssertThrowsError(try CangjieTable.parse("日 日 1 1")) { XCTAssertEqual($0 as? ImeDataError, .badLine(1)) }
    }
    func testHanRangesMatchCore() {
        XCTAssertTrue(Han.isAllHan("嘅"))
        XCTAssertTrue(Han.isAllHan("𠮷"))
        XCTAssertFalse(Han.isAllHan("a嘅"))
        XCTAssertFalse(Han.isAllHan(""))
    }
}
