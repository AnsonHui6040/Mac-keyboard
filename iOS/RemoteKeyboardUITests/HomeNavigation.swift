import XCTest

extension XCUIApplication {
    /// Launches without the first launch guide and opens 幫助 › 測試輸入, where `rk.home.testInput` lives.
    func launchAtTestInput() {
        launchArguments += ["-rkSkipOnboarding"]
        launch()
        let link = descendants(matching: .any).matching(identifier: "rk.home.testInputLink").firstMatch
        if link.waitForExistence(timeout: 10) { link.tap() }
    }
}
