import XCTest
@testable import RemoteKeyboardCore

final class CangjieRadicalsTests: XCTestCase {
    func testRadicalMappingCoversAToZ() {
        XCTAssertEqual(CangjieRadicals.byLetter.count, 26)
        XCTAssertEqual(CangjieRadicals.byLetter["a"], "日")
        XCTAssertEqual(CangjieRadicals.byLetter["x"], "難")
        XCTAssertEqual(CangjieRadicals.byLetter["z"], "重")
        for scalar in "abcdefghijklmnopqrstuvwxyz" {
            XCTAssertNotNil(CangjieRadicals.byLetter[scalar], "missing \(scalar)")
        }
    }

    func testRadicalsAreTheFixedTable() {
        let expected = "日月金木水火土竹戈十大中一弓人心手口尸廿山女田難卜重"
        let actual = "abcdefghijklmnopqrstuvwxyz".map { CangjieRadicals.byLetter[$0] ?? "?" }.joined()
        XCTAssertEqual(actual, expected)
    }

    func testDisplayMapsCodeToRadicals() {
        XCTAssertEqual(CangjieRadicals.display(for: "ab"), "日月")
        XCTAssertEqual(CangjieRadicals.display(for: ""), "")
    }
}
