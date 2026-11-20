import XCTest
@testable import RemoteKeyboardCore

final class ChineseInputMethodIDTests: XCTestCase {
    func testCasesAndNames() {
        XCTAssertEqual(
            ChineseInputMethodID.allCases.map(\.rawValue),
            ["handwriting", "quick", "cangjie", "zhuyin", "jyutping", "pinyin"])
        XCTAssertEqual(ChineseInputMethodID.allCases.map(\.displayName), ["手寫", "速成", "倉頡", "注音", "粵拼", "拼音"])
        XCTAssertEqual(ChineseInputMethodID.allCases.filter(\.isKeyed).count, 5)
    }

    func testOldStoredValuesStillDecode() {
        XCTAssertEqual(ChineseInputMethodID.stored(rawValue: "handwriting"), .handwriting)
        XCTAssertEqual(ChineseInputMethodID.stored(rawValue: "quick"), .quick)
        XCTAssertEqual(ChineseInputMethodID.stored(rawValue: "zhuyin"), .zhuyin)
        XCTAssertNil(ChineseInputMethodID.stored(rawValue: "unknown"))
    }
}
