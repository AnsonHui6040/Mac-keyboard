import XCTest
@testable import RemoteKeyboardCore

final class ModelFileNamingTests: XCTestCase {
    private let host = "com.ansonhui.remotekeyboard"
    private let own = "com.ansonhui.remotekeyboard.keyboard"

    func testHostPrefixBecomesTheExtensionPrefix() {
        XCTAssertEqual(
            ModelFileNaming.rekey("\(host).com.google.mlkit.mdd.1234", from: host, to: own),
            "\(own).com.google.mlkit.mdd.1234")
    }

    func testNamesAlreadyForTheExtensionAreKept() {
        let name = "\(own).com.google.mlkit.mdd.1234"
        XCTAssertEqual(ModelFileNaming.rekey(name, from: host, to: own), name)
    }

    func testUnrelatedNamesAreKept() {
        XCTAssertEqual(ModelFileNaming.rekey("FileGroupMetadata", from: host, to: own), "FileGroupMetadata")
        XCTAssertEqual(ModelFileNaming.rekey("\(host)x.y", from: host, to: own), "\(host)x.y")
    }

    func testSameIdsChangeNothing() {
        XCTAssertEqual(ModelFileNaming.rekey("\(host).a", from: host, to: host), "\(host).a")
    }
}
