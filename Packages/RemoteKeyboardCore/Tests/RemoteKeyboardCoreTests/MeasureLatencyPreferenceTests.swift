#if DEBUG
import XCTest
@testable import RemoteKeyboardCore

final class MeasureLatencyPreferenceTests: XCTestCase {
    func testParsesTheEnvironmentValue() {
        XCTAssertEqual(MeasureLatencyPreference(environmentValue: "low"), .low)
        XCTAssertEqual(MeasureLatencyPreference(environmentValue: "medium"), .medium)
        XCTAssertEqual(MeasureLatencyPreference(environmentValue: "none"), .none)
        XCTAssertEqual(MeasureLatencyPreference(environmentValue: "LOW"), .low)
    }

    func testDefaultIsLow() {
        XCTAssertEqual(MeasureLatencyPreference(environmentValue: nil), .low)
        XCTAssertEqual(MeasureLatencyPreference(environmentValue: ""), .low)
        XCTAssertEqual(MeasureLatencyPreference(environmentValue: "fast"), .low, "an unknown value does not silently turn it off")
        XCTAssertEqual(MeasureLatencyPreference.default, .low)
    }

    func testNamesAndTheSettleTime() {
        XCTAssertEqual(MeasureLatencyPreference.low.name, "low")
        XCTAssertEqual(MeasureLatencyPreference.medium.name, "medium")
        XCTAssertEqual(MeasureLatencyPreference.none.name, "none")
        XCTAssertEqual(MeasureLatencyPreference.settleSeconds, 2)
        XCTAssertEqual(MeasureLatencyPreference.evidenceWindowSeconds, 5)
        XCTAssertFalse(MeasureLatencyPreference.none.isRequested)
        XCTAssertTrue(MeasureLatencyPreference.low.isRequested)
    }
}
#endif
