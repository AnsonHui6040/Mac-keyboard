import XCTest

/// Quick (速成) typed through the real keyboard on the simulator: select 速成 in the app's 中文輸入 settings, open the
/// 測試輸入 field, switch to the Remote Keyboard in Local mode, go to the Chinese page, tap `rk.quick.a`, `rk.quick.b`
/// and the space key, and check the field. The first test runs the default engine (librime); the second sets
/// `RKMEAS_QUICK_ENGINE=swift` so the Swift engine types the same thing. Neither prints the field's text.
@MainActor
final class QuickRimeUITests: XCTestCase {
    private static let nextKeyboardNames = ["Next keyboard", "下一個鍵盤", "地球", "Globe", "下一個輸入法"]
    private static let localModeValue = "本機"
    private static let placeholder = "在這裡輸入"
    private static let expected = "明"

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testQuickTypesThroughRime() throws {
        try typeAB(engineOverride: nil)
    }

    func testQuickTypesThroughSwiftWhenOverridden() throws {
        try typeAB(engineOverride: "swift")
    }

    private func typeAB(engineOverride: String?) throws {
        app = XCUIApplication()
        if let engineOverride { app.launchEnvironment["RKMEAS_QUICK_ENGINE"] = engineOverride }
        app.launchArguments += ["-rkSkipOnboarding"]
        app.launch()

        let chineseLink = element("rk.home.chineseInput")
        XCTAssertTrue(chineseLink.waitForExistence(timeout: 10), "中文輸入與手寫 link not found")
        chineseLink.tap()
        let quickRow = element("rk.settings.quick")
        XCTAssertTrue(quickRow.waitForExistence(timeout: 10), "速成 row not found")
        quickRow.tap()
        app.navigationBars.buttons.firstMatch.tap()

        let testInputLink = element("rk.home.testInputLink")
        XCTAssertTrue(testInputLink.waitForExistence(timeout: 10), "測試輸入 link not found")
        testInputLink.tap()
        let field = app.textFields["rk.home.testInput"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the 測試輸入 field was not found")
        field.tap()

        try openOurKeyboardInLocalMode()
        let zhEn = element("rk.zhEn")
        if !element("rk.quick.a").exists {
            XCTAssertTrue(zhEn.waitForExistence(timeout: 5), "中英 key not found")
            zhEn.tap()
        }
        let keyA = element("rk.quick.a"), keyB = element("rk.quick.b")
        XCTAssertTrue(keyA.waitForExistence(timeout: 10), "rk.quick.a not found")
        keyA.tap()
        keyB.tap()
        element("rk.space").tap()

        let deadline = Date().addingTimeInterval(5)
        var text = fieldText(field)
        while text != Self.expected, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            text = fieldText(field)
        }
        XCTAssertEqual(text, Self.expected)
    }

    // MARK: Steps

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func fieldText(_ field: XCUIElement) -> String {
        let value = field.value as? String ?? ""
        return value == Self.placeholder ? "" : value
    }

    /// The globe key until the Remote Keyboard shows, then Local mode.
    private func openOurKeyboardInLocalMode() throws {
        let mode = element("rk.mode")
        var found = mode.waitForExistence(timeout: 5)
        var tries = 0
        while !found && tries < 6 {
            tries += 1
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
            guard let next = nextKeyboardButton() else { break }
            next.tap()
            found = mode.waitForExistence(timeout: 2)
        }
        guard found else { throw XCTSkip("Remote Keyboard is not reachable from the globe key") }
        if (mode.value as? String) != Self.localModeValue {
            mode.tap()
            let deadline = Date().addingTimeInterval(5)
            while (mode.value as? String) != Self.localModeValue, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        }
        guard (mode.value as? String) == Self.localModeValue else { throw XCTSkip("could not switch to Local mode") }
    }

    private func nextKeyboardButton() -> XCUIElement? {
        guard app.keyboards.firstMatch.exists else { return nil }
        let minY = app.frame.minY + app.frame.height * 0.85
        for name in Self.nextKeyboardNames {
            let inside = app.keyboards.buttons[name]
            if inside.exists { return inside }
            let query = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", name, name))
            for button in query.allElementsBoundByIndex.prefix(10) where button.frame.minY >= minY { return button }
        }
        return nil
    }
}
