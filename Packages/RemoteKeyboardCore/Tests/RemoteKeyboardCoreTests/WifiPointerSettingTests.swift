import XCTest
@testable import RemoteKeyboardCore

/// 「經 Wi-Fi 傳送游標」: a `Bool` in the App Group, written by the host App and read by the keyboard (spec W11).
final class WifiPointerSettingTests: XCTestCase {
    func testNotSetMeansOn() {
        XCTAssertTrue(WifiPointerSetting.isEnabled(stored: nil))
        XCTAssertTrue(WifiPointerSetting.defaultValue)
    }

    func testExplicitValuesAreKept() {
        XCTAssertTrue(WifiPointerSetting.isEnabled(stored: true))
        XCTAssertFalse(WifiPointerSetting.isEnabled(stored: false))
    }

    func testSomethingThatIsNotABoolMeansOn() {
        XCTAssertTrue(WifiPointerSetting.isEnabled(stored: "no"))
        XCTAssertTrue(WifiPointerSetting.isEnabled(stored: [false]))
    }

    func testTheKeyLivesInTheAppGroupNamespace() {
        XCTAssertEqual(AppGroup.Key.wifiPointer, "rk.wifiPointer")
    }

    func testTheValueSurvivesARealDefaultsSuite() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "wifi-pointer-setting-test"))
        defer { suite.removePersistentDomain(forName: "wifi-pointer-setting-test") }
        XCTAssertTrue(WifiPointerSetting.isEnabled(stored: suite.object(forKey: AppGroup.Key.wifiPointer)))
        suite.set(false, forKey: AppGroup.Key.wifiPointer)
        XCTAssertFalse(WifiPointerSetting.isEnabled(stored: suite.object(forKey: AppGroup.Key.wifiPointer)))
    }
}
