import RemoteKeyboardCore
import XCTest
@testable import RimeEngine

final class ZhuyinLayoutTests: XCTestCase {
    func testLayoutLabelsMatchSchemaPreeditFormat() throws {
        let layout = try KeyboardLayout.decode(Data(contentsOf: Repo.root.appending(path: "ime/layouts/zhuyin-standard.json")))
        let schema = try String(contentsOf: Repo.root.appending(path: "ime/rime/zhuyin.schema.yaml"), encoding: .utf8)
        let xlit = try XCTUnwrap(schema.components(separatedBy: "xlit|").dropFirst().first).split(separator: "|")
        let mapping = Dictionary(uniqueKeysWithValues: zip(xlit[0].map(String.init), xlit[1].map(String.init)))
        var fromLayout: [String: String] = [:]
        for key in layout.rows.joined() { if let code = key.code { fromLayout[code] = key.label } }
        XCTAssertEqual(fromLayout, mapping)
        XCTAssertEqual(Set(fromLayout.keys.map { Character($0) }), RimeSchemeConfig.zhuyin.keys)
    }
}
