import XCTest
@testable import RemoteKeyboardCore

final class SystemSettingsLinkTests: XCTestCase {
    func testAccessibilityString() {
        XCTAssertEqual(
            SystemSettingsLink.accessibility.urlString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func testBluetoothPrivacyString() {
        XCTAssertEqual(
            SystemSettingsLink.bluetoothPrivacy.urlString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
    }

    func testLoginItemsString() {
        XCTAssertEqual(
            SystemSettingsLink.loginItems.urlString,
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")
    }

    func testEveryCaseFormsAURL() {
        for link in SystemSettingsLink.allCases {
            XCTAssertNotNil(URL(string: link.urlString), "\(link)")
        }
    }

    func testThreeCases() {
        XCTAssertEqual(SystemSettingsLink.allCases.count, 3)
    }
}
