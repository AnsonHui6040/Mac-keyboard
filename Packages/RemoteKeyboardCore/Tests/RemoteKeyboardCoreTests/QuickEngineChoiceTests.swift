import XCTest
@testable import RemoteKeyboardCore

final class QuickEngineChoiceTests: XCTestCase {
    func testRimeIsDefaultWhenStarted() { XCTAssertEqual(QuickEngineChoice.decide(override: nil, rimeStarted: true), .rime) }
    func testSwiftWhenRimeFailed() { XCTAssertEqual(QuickEngineChoice.decide(override: nil, rimeStarted: false), .swift) }
    func testDebugOverrideToSwift() { XCTAssertEqual(QuickEngineChoice.decide(override: "swift", rimeStarted: true), .swift) }
    func testOverrideToRimeCannotForceAFailedRuntime() { XCTAssertEqual(QuickEngineChoice.decide(override: "rime", rimeStarted: false), .swift) }
    func testUnknownOverrideIsIgnored() { XCTAssertEqual(QuickEngineChoice.decide(override: "x", rimeStarted: true), .rime) }
}
