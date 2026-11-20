import RemoteKeyboardCore
import XCTest
@testable import RimeEngine

final class RimeSchemeConfigTests: XCTestCase {
    func testConfigs() {
        XCTAssertNil(RimeSchemeConfig.forMethod(.handwriting))
        XCTAssertEqual(RimeSchemeConfig.forMethod(.zhuyin)?.keys.count, 41)
        XCTAssertEqual(RimeSchemeConfig.forMethod(.cangjie)?.maxCodeLength, 5)
        XCTAssertEqual(RimeSchemeConfig.forMethod(.quick), .quick5)
    }

    func testEveryConfigPassesItsHealthCheck() throws {
        let runtime = try RimeRuntime.start(RimeFixture.compiled("fixture"))
        for config in [RimeSchemeConfig.quick5, .cangjie5, .zhuyin, .pinyin, .jyutping] {
            XCTAssertTrue(try runtime.makeSession(schema: config.schema).isHealthy(probeKey: config.probeKey), config.schema)
        }
    }
}
