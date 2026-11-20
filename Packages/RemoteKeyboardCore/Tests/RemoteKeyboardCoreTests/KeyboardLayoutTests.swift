import XCTest
@testable import RemoteKeyboardCore

final class KeyboardLayoutTests: XCTestCase {
    private func layout(_ rows: String) -> Data {
        Data(#"{"id":"t","name":"t","version":1,"schemas":["x"],"rows":\#(rows)}"#.utf8)
    }
    func testRejectsInvalidLayouts() {
        XCTAssertThrowsError(try KeyboardLayout.decode(Data("{".utf8))) { XCTAssertEqual($0 as? KeyboardLayoutError, .invalidJSON) }
        XCTAssertThrowsError(try KeyboardLayout.decode(layout("[]"))) { XCTAssertEqual($0 as? KeyboardLayoutError, .noRows) }
        XCTAssertThrowsError(try KeyboardLayout.decode(layout("[[]]"))) { XCTAssertEqual($0 as? KeyboardLayoutError, .emptyRow(0)) }
        XCTAssertThrowsError(try KeyboardLayout.decode(layout(#"[[{"label":"x"}]]"#))) {
            XCTAssertEqual($0 as? KeyboardLayoutError, .keyNeedsCodeOrAction(row: 0, index: 0)) }
        XCTAssertThrowsError(try KeyboardLayout.decode(layout(#"[[{"code":"a","action":"shift"}]]"#))) {
            XCTAssertEqual($0 as? KeyboardLayoutError, .keyNeedsCodeOrAction(row: 0, index: 0)) }
        XCTAssertThrowsError(try KeyboardLayout.decode(layout(#"[[{"code":"a","width":5}]]"#))) {
            XCTAssertEqual($0 as? KeyboardLayoutError, .badWidth(row: 0, index: 0)) }
        XCTAssertThrowsError(try KeyboardLayout.decode(layout(#"[[{"code":"a"},{"code":"a"}]]"#))) {
            XCTAssertEqual($0 as? KeyboardLayoutError, .duplicateCode("a")) }
    }
    func testQwertyGeometry() throws {
        let keys = { (s: String) in "[" + s.map { #"{"code":"\#($0)"}"# }.joined(separator: ",") + "]" }
        let middle = String(keys("zxcvbnm").dropFirst().dropLast())
        let rows = "[\(keys("qwertyuiop")),\(keys("asdfghjkl")),[{\"action\":\"shift\",\"width\":1.5},"
            + middle + ",{\"action\":\"backspace\",\"width\":1.5}]]"
        let frames = KeyboardLayoutGeometry.frames(try KeyboardLayout.decode(layout(rows)), width: 354, gap: 6)
        XCTAssertEqual(frames[0].map(\.x).prefix(3), [0, 36, 72])
        XCTAssertEqual(frames[0][0].width, 30)
        XCTAssertEqual(frames[1][0].x, 18)
        XCTAssertEqual(frames[2][0], LayoutKeyFrame(x: 3, width: 45))
        XCTAssertEqual(frames[2][1].x, 54)
        XCTAssertEqual(frames[2][8], LayoutKeyFrame(x: 306, width: 45))
    }
    func testRejectsVersionAndSizeLimits() {
        let row = { (n: Int, from: Int) in "[" + (0..<n).map { #"{"code":"k\#($0 + from)"}"# }.joined(separator: ",") + "]" }
        XCTAssertThrowsError(try KeyboardLayout.decode(Data(#"{"id":"t","name":"t","version":2,"schemas":["x"],"rows":[[{"code":"a"}]]}"#.utf8))) {
            XCTAssertEqual($0 as? KeyboardLayoutError, .unsupportedVersion(2)) }
        XCTAssertNoThrow(try KeyboardLayout.decode(layout("[" + (0..<6).map { row(1, $0) }.joined(separator: ",") + "]")))
        XCTAssertThrowsError(try KeyboardLayout.decode(layout("[" + (0..<7).map { row(1, $0) }.joined(separator: ",") + "]"))) {
            XCTAssertEqual($0 as? KeyboardLayoutError, .tooManyRows(7)) }
        XCTAssertNoThrow(try KeyboardLayout.decode(layout("[\(row(30, 0)),\(row(30, 30))]")))
        XCTAssertThrowsError(try KeyboardLayout.decode(layout("[\(row(30, 0)),\(row(31, 30))]"))) {
            XCTAssertEqual($0 as? KeyboardLayoutError, .tooManyKeys(61)) }
    }
    func testWidthBoundsAndEmptyCode() {
        XCTAssertNoThrow(try KeyboardLayout.decode(layout(#"[[{"code":"a","width":0.5},{"code":"b","width":4}]]"#)))
        for bad in ["0.49", "4.01", "0", "-1"] {
            XCTAssertThrowsError(try KeyboardLayout.decode(layout(#"[[{"code":"a","width":\#(bad)}]]"#))) {
                XCTAssertEqual($0 as? KeyboardLayoutError, .badWidth(row: 0, index: 0)) }
        }
        XCTAssertThrowsError(try KeyboardLayout.decode(layout(#"[[{"code":""}]]"#))) {
            XCTAssertEqual($0 as? KeyboardLayoutError, .keyNeedsCodeOrAction(row: 0, index: 0)) }
        XCTAssertEqual(KeyboardLayoutGeometry.height(rows: 0), 0)
    }
    func testExtraKeyRowAddsOneRow() {
        XCTAssertEqual(KeyboardMetrics.height(visibleTopRows: 2, handwriting: false, extraKeyRows: 1),
                       KeyboardMetrics.height(visibleTopRows: 2) + 54)
    }
}

final class BundledLayoutsTests: XCTestCase {
    private let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "ime/layouts")
    private func load(_ id: String) throws -> KeyboardLayout {
        try KeyboardLayout.decode(Data(contentsOf: folder.appending(path: "\(id).json")))
    }
    func testEveryKeyedMethodHasAValidLayout() throws {
        for method in ChineseInputMethodID.allCases where method.isKeyed {
            XCTAssertEqual(try load(XCTUnwrap(method.layoutID)).id, method.layoutID)
        }
    }
    func testCangjieLabelsAreRadicals() throws {
        for key in try load("cangjie-qwerty").rows.joined() where key.code != nil {
            XCTAssertEqual(key.label, CangjieRadicals.byLetter[Character(key.code!)])
        }
    }
    func testZhuyinHasFourRowsOfKeys() throws {
        let zhuyin = try load("zhuyin-standard")
        XCTAssertEqual(zhuyin.rows.map(\.count), [11, 10, 10, 11])
        XCTAssertEqual(zhuyin.rows.joined().compactMap(\.code).count, 41)
    }
}
