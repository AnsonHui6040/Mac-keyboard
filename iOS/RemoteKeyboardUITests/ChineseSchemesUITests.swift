import XCTest

/// The five keyed Chinese methods typed through the real keyboard on the simulator: pick the method in the app's 中文輸入
/// settings, open the 測試輸入 field, switch to the Remote Keyboard in Local mode, go to the Chinese page, tap
/// `rk.ime.<key>` keys, tap the candidate and check the field. The check never prints the field's text.
@MainActor
final class ChineseSchemesUITests: XCTestCase {
    private static let nextKeyboardNames = ["Next keyboard", "下一個鍵盤", "地球", "Globe", "下一個輸入法"]
    private static let localModeValue = "本機"
    private static let placeholder = "在這裡輸入"

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testCangjieTypesMing() {
        launch()
        chooseMethod("cangjie")
        openKeyboardOnChinesePage()
        attachScreenshot("cangjie-page")
        let field = testField()
        tapKeys(["a", "b"])
        pickCandidate("明")
        XCTAssertEqual(waitForText("明", in: field), "明")
    }

    func testZhuyinTypesTaiwan() {
        launch()
        chooseMethod("zhuyin")
        openKeyboardOnChinesePage()
        attachScreenshot("zhuyin-page")
        let field = testField()
        tapKeys(["w", "9", "6", "j", "0"])
        pickCandidate("台灣")
        XCTAssertEqual(waitForText("台灣", in: field), "台灣")
    }

    func testPinyinTypesTaiwan() {
        launch()
        chooseMethod("pinyin")
        openKeyboardOnChinesePage()
        attachScreenshot("pinyin-page")
        let field = testField()
        tapKeys(["t", "a", "i", "w", "a", "n"])
        pickCandidate("台灣")
        XCTAssertEqual(waitForText("台灣", in: field), "台灣")
    }

    func testJyutpingTypesNgo() {
        launch()
        chooseMethod("jyutping")
        openKeyboardOnChinesePage()
        let field = testField()
        tapKeys(["n", "g", "o"])
        pickCandidate("我")
        XCTAssertEqual(waitForText("我", in: field), "我")
    }

    /// The keyboard extension's process may outlive one appearance: a scheme changed in the app between two
    /// appearances must be the one the second appearance uses. The 測試輸入 field is a new view after the trip through
    /// the settings, so the second appearance starts with an empty field.
    func testSwitchingSchemeTakesEffectOnReopen() {
        launch()
        chooseMethod("pinyin")
        openKeyboardOnChinesePage()
        let field = testField()
        tapKeys(["t", "a", "i", "w", "a", "n"])
        pickCandidate("台灣")
        XCTAssertEqual(waitForText("台灣", in: field), "台灣")

        // Close the keyboard (leave the field), change the scheme in the app, bring the keyboard up again.
        app.navigationBars.buttons.firstMatch.tap()
        chooseMethod("jyutping")
        openKeyboardOnChinesePage()
        let again = testField()
        tapKeys(["n", "g", "o"])
        pickCandidate("我")
        XCTAssertEqual(waitForText("我", in: again), "我")
    }

    // MARK: Steps

    private func launch() {
        app = XCUIApplication()
        app.launchArguments += ["-rkSkipOnboarding"]
        app.launch()
        // Whatever fails below, the method goes back to 速成 so the other UI tests start from the default.
        addTeardownBlock { @MainActor [weak self] in self?.restoreQuick() }
    }

    /// From the home screen: 中文輸入與手寫, the method row, back to home. Only `rk.settings.<rawValue>` is tapped.
    private func chooseMethod(_ rawValue: String) {
        let chineseLink = element("rk.home.chineseInput")
        XCTAssertTrue(chineseLink.waitForExistence(timeout: 10), "中文輸入與手寫 link not found")
        chineseLink.tap()
        let row = element("rk.settings.\(rawValue)")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "rk.settings.\(rawValue) row not found")
        row.tap()
        app.navigationBars.buttons.firstMatch.tap()
    }

    /// Teardown: from wherever the test stopped back to home, then 速成 again. No assertions: an element that is not
    /// there (the test failed early, the app is gone) just ends the restore.
    private func restoreQuick() {
        guard let app, app.state == .runningForeground else { return }
        let chineseLink = element("rk.home.chineseInput")
        var steps = 0
        while !chineseLink.waitForExistence(timeout: 1), steps < 3 {
            steps += 1
            let back = app.navigationBars.buttons.firstMatch
            guard back.exists else { break }
            back.tap()
        }
        guard chineseLink.exists else { return }
        chineseLink.tap()
        let row = element("rk.settings.quick")
        guard row.waitForExistence(timeout: 5) else { return }
        row.tap()
    }

    private func openKeyboardOnChinesePage() {
        let testInputLink = element("rk.home.testInputLink")
        XCTAssertTrue(testInputLink.waitForExistence(timeout: 10), "測試輸入 link not found")
        testInputLink.tap()
        let field = testField()
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the 測試輸入 field was not found")
        field.tap()
        openOurKeyboardInLocalMode()
        // The Chinese page shows keys named rk.ime.*; the 中英 key switches to it from the English page.
        if !element("rk.ime.backspace").exists {
            let zhEn = element("rk.zhEn")
            XCTAssertTrue(zhEn.waitForExistence(timeout: 5), "中英 key not found")
            zhEn.tap()
        }
        XCTAssertTrue(element("rk.ime.backspace").waitForExistence(timeout: 10), "the Chinese page did not show")
    }

    /// The whole screen as a kept attachment of the test result, so the page can be looked at afterwards.
    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tapKeys(_ keys: [String]) {
        for key in keys {
            let button = element("rk.ime.\(key)")
            XCTAssertTrue(button.waitForExistence(timeout: 10), "rk.ime.\(key) not found")
            button.tap()
        }
    }

    /// Taps the candidate (identifier `rk.candidate.<n>`) whose label is `text`.
    private func pickCandidate(_ text: String) {
        let query = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'rk.candidate.' AND label == %@", text))
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 10), "candidate not shown")
        query.firstMatch.tap()
    }

    private func testField() -> XCUIElement { app.textFields["rk.home.testInput"] }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func fieldText(_ field: XCUIElement) -> String {
        let value = field.value as? String ?? ""
        return value == Self.placeholder ? "" : value
    }

    private func waitForText(_ expected: String, in field: XCUIElement) -> String {
        let deadline = Date().addingTimeInterval(5)
        var text = fieldText(field)
        while text != expected, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            text = fieldText(field)
        }
        return text
    }

    /// The globe key until the Remote Keyboard shows, then Local mode.
    private func openOurKeyboardInLocalMode() {
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
        guard found else {
            XCTFail("Remote Keyboard is not reachable from the globe key")
            return
        }
        if (mode.value as? String) != Self.localModeValue {
            mode.tap()
            let deadline = Date().addingTimeInterval(5)
            while (mode.value as? String) != Self.localModeValue, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        }
        guard (mode.value as? String) == Self.localModeValue else {
            XCTFail("could not switch to Local mode")
            return
        }
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
