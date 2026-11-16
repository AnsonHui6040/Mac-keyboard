import XCTest

/// Sets 「經 Wi-Fi 傳送游標」 in the app's 設定 › 觸控板 from outside, for the Wi-Fi assist device runs (e2e/scripts/measure-trackpad.sh).
///
/// `RK_WIFI_POINTER` (`on` or `off`, default `on`; `TEST_RUNNER_` prefix on the xcodebuild side) is the value to set. Visiting the
/// page, and switching the toggle on, make the app ask for the Local Network permission; the alert is allowed here (never
/// 「不允許」). Prints only `RKWIFI setting=<on|off> alert=<allowed|none>`.
@MainActor
final class WifiPointerSettingUITests: XCTestCase {
    private static let allowLabels = ["允許", "Allow", "好", "OK"]

    private var app: XCUIApplication!
    private var alertAllowed = false

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testSetWifiPointer() throws {
        let raw = (ProcessInfo.processInfo.environment["RK_WIFI_POINTER"] ?? "on").lowercased()
        guard raw == "on" || raw == "off" else {
            XCTFail("RK_WIFI_POINTER must be on or off, got [\(raw)]")
            return
        }
        let wantOn = raw == "on"

        app = XCUIApplication()
        app.launchArguments += ["-rkSkipOnboarding"]
        app.launch()

        let link = element("rk.home.trackpad")
        XCTAssertTrue(link.waitForExistence(timeout: 10), "觸控板 (rk.home.trackpad) not found")
        link.tap()

        let toggle = element("rk.settings.wifiPointer")
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "經 Wi-Fi 傳送游標 (rk.settings.wifiPointer) not found")
        // The page asks for the permission when it appears with the setting on.
        allowLocalNetworkAlert()

        if isOn(toggle) != wantOn {
            tapSwitch(toggle)
            XCTAssertTrue(wait(5) { isOn(toggle) == wantOn }, "the toggle did not become \(raw)")
        }
        if wantOn { allowLocalNetworkAlert() }
        XCTAssertEqual(isOn(toggle), wantOn, "the toggle is not \(raw) at the end")
        print("RKWIFI setting=\(wantOn ? "on" : "off") alert=\(alertAllowed ? "allowed" : "none")")
    }

    // MARK: Steps

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func isOn(_ toggle: XCUIElement) -> Bool {
        let value = toggle.value as? String
        return value == "1" || value == "on" || value == "開"
    }

    /// The row may be one element covering the whole line: the switch sits at its right end.
    private func tapSwitch(_ toggle: XCUIElement) {
        let inner = toggle.switches.firstMatch
        if toggle.elementType != .switch, inner.exists {
            inner.tap()
        } else {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
    }

    /// Waits up to about 5 s for the system alert and taps its allow button. Never taps 不允許 / Don't Allow.
    private func allowLocalNetworkAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(5)
        repeat {
            let alert = springboard.alerts.firstMatch
            if alert.exists {
                for name in Self.allowLabels {
                    let button = alert.buttons[name]
                    if button.exists {
                        button.tap()
                        alertAllowed = true
                        return
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
    }

    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }
}
