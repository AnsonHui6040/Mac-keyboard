import XCTest

final class LicenseBlockTests: XCTestCase {
    func testMcBopomofoLicenseIsVerbatim() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let notice = try String(contentsOf: root.appending(path: "ime/rime/LICENSE-data.txt"), encoding: .utf8)
        let source = try String(contentsOf: root.appending(path: "build/rime/src/mcbopomofo/LICENSE.txt"), encoding: .utf8)
        let block = notice.components(separatedBy: "----- BEGIN McBopomofo LICENSE.txt -----\n")[1]
            .components(separatedBy: "----- END McBopomofo LICENSE.txt -----")[0]
        XCTAssertEqual(block, source)
    }
}
