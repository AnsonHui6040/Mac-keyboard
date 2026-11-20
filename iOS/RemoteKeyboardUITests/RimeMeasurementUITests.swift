import XCTest

/// Device measurement of a librime scheme (latency, memory, staging, App Group read). `RKMEAS_SCHEME` is `quick`
/// (default), `cangjie`, `zhuyin`, `pinyin` or `jyutping`. Types that scheme's fixed sequence (`sequences` below; Quick:
/// `ab hd oi mm lw`) through the real keyboard until `RKMEAS_RIME_KEYS` keys (default 200) were tapped, then switches the
/// Chinese method to 手寫 in the host App and opens the keyboard on the Chinese page for 10 s (this loads the handwriting
/// model), reads the DEBUG element `rk.debug.rimeMeasure`, prints and attaches its line as `rime-measure-<engine>-<scheme>.txt`,
/// and puts the setting back to 速成. `RKMEAS_QUICK_ENGINE` is `rime` (default) or `swift`; `swift` only exists for `quick`. Device only: the simulator
/// skips the test. Numbers only: no typed text is read or printed. The handwriting model has to be downloaded in the App
/// beforehand.
@MainActor
final class RimeMeasurementUITests: XCTestCase {
    private static let nextKeyboardNames = ["Next keyboard", "下一個鍵盤", "地球", "Globe", "下一個輸入法"]
    private static let localModeValue = "本機"
    private static let sequences: [String: String] = [
        "quick": "ab hd oi mm lw",
        "cangjie": "ab hqi onf a",
        "zhuyin": "ji3 su3 w96j0 2u04sl3",
        "pinyin": "wo ni taiwan diannao",
        "jyutping": "ngo nei hai mgoi",
    ]
    private static let handwritingHold: TimeInterval = 10

    private static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testQuickEngineMeasurement() throws {
        try XCTSkipIf(Self.isSimulator, "the Quick engine measurement runs on a real iPhone only")
        let environment = ProcessInfo.processInfo.environment
        let engine = environment["RKMEAS_QUICK_ENGINE"] == "swift" ? "swift" : "rime"
        let target = Int(environment["RKMEAS_RIME_KEYS"] ?? "") ?? 200
        let scheme = environment["RKMEAS_SCHEME"] ?? "quick"
        guard let sequence = Self.sequences[scheme].map({ Array($0) }) else {
            XCTFail("RKMEAS_SCHEME \(scheme) is not one of \(Self.sequences.keys.sorted())")
            return
        }
        if engine == "swift", scheme != "quick" {
            XCTFail("RKMEAS_QUICK_ENGINE=swift only exists for the quick scheme, not \(scheme)")
            return
        }

        app = XCUIApplication()
        app.launchEnvironment["RKMEAS_QUICK_ENGINE"] = engine
        app.launchArguments += ["-rkSkipOnboarding"]
        app.launch()
        // A failed assertion stops the test before step 4, so put the iPhone back on 速成 in any case.
        addTeardownBlock { @MainActor [weak self] in self?.restoreQuickTolerantly() }

        // 1. The scheme, typed through the keyboard.
        selectMethod("rk.settings.\(scheme)")
        openKeyboardOnChinesePage()
        try typeSequence(sequence, keys: target)

        // 2. 手寫: the model must be there; the keyboard stays on the Chinese page for a while.
        leaveTestInput()
        selectMethod("rk.settings.handwriting", requiringModel: true)
        openKeyboardOnChinesePage()
        Thread.sleep(forTimeInterval: Self.handwritingHold)

        // 3. The line.
        let measure = element("rk.debug.rimeMeasure")
        XCTAssertTrue(measure.waitForExistence(timeout: 10), "rk.debug.rimeMeasure not found")
        let line = measure.value as? String ?? ""
        XCTAssertTrue(line.hasPrefix("RKMEAS RIME engine=\(engine) scheme=\(scheme) "), "unexpected measurement line: \(line)")
        // The probe lives in the extension process, so keys can add up across runs: at least the target is enough.
        let keysValue = line.components(separatedBy: " ").first { $0.hasPrefix("keys=") }.flatMap { Int($0.dropFirst(5)) }
        XCTAssertGreaterThanOrEqual(keysValue ?? -1, target, "keys= is missing or below \(target): \(line)")
        XCTAssertTrue(line.contains(" appgroup_read="), "appgroup_read= is missing: \(line)")
        print(line)
        let attachment = XCTAttachment(string: line + "\n")
        attachment.name = "rime-measure-\(engine)-\(scheme).txt"
        attachment.lifetime = .keepAlways
        add(attachment)

        // 4. Back to 速成.
        leaveTestInput()
        selectMethod("rk.settings.quick")
    }

    // MARK: Steps

    /// Relaunches the App and selects 速成 without asserting, so a failing teardown cannot hide the real failure.
    private func restoreQuickTolerantly() {
        guard let app else { return }
        app.terminate()
        app.launch()
        let link = element("rk.home.chineseInput")
        guard link.waitForExistence(timeout: 10) else { return }
        link.tap()
        let row = element("rk.settings.quick")
        guard row.waitForExistence(timeout: 10) else { return }
        row.tap()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Home -> 中文輸入與手寫 -> pick the row -> Home. With `requiringModel` the 手寫 model has to exist (the delete button is enabled).
    private func selectMethod(_ rowIdentifier: String, requiringModel: Bool = false) {
        let link = element("rk.home.chineseInput")
        XCTAssertTrue(link.waitForExistence(timeout: 10), "中文輸入與手寫 link not found")
        link.tap()
        let row = element(rowIdentifier)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(rowIdentifier) row not found")
        row.tap()
        if requiringModel {
            let delete = element("rk.settings.delete")
            XCTAssertTrue(delete.waitForExistence(timeout: 5) && delete.isEnabled,
                          "the handwriting model is not downloaded: download it in the App (中文輸入與手寫) first")
        }
        app.navigationBars.buttons.firstMatch.tap()
    }

    /// Test input field -> our keyboard in Local mode -> the Chinese page.
    private func openKeyboardOnChinesePage() {
        let testInputLink = element("rk.home.testInputLink")
        XCTAssertTrue(testInputLink.waitForExistence(timeout: 10), "測試輸入 link not found")
        testInputLink.tap()
        let field = app.textFields["rk.home.testInput"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the 測試輸入 field was not found")
        field.tap()
        openOurKeyboardInLocalMode()
        let zhEn = element("rk.zhEn")
        if !element("rk.ime.backspace").exists, !element("rk.hwClear").exists {
            XCTAssertTrue(zhEn.waitForExistence(timeout: 5), "中英 key not found")
            zhEn.tap()
        }
    }

    /// Leaves the 測試輸入 page, which closes the keyboard.
    private func leaveTestInput() {
        app.navigationBars.buttons.firstMatch.tap()
    }

    private func typeSequence(_ sequence: [Character], keys target: Int) throws {
        var letterKeys: [Character: XCUIElement] = [:]
        let space = element("rk.space")
        XCTAssertTrue(element("rk.ime.\(sequence[0])").waitForExistence(timeout: 10), "rk.ime.\(sequence[0]) not found")
        var tapped = 0
        while tapped < target {
            let character = sequence[tapped % sequence.count]
            if character == " " {
                space.tap()
            } else {
                if letterKeys[character] == nil { letterKeys[character] = element("rk.ime.\(character)") }
                letterKeys[character]!.tap()
            }
            tapped += 1
        }
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
