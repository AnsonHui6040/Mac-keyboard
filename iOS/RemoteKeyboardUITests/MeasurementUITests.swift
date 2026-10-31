import XCTest

/// TP1 measurements M2, M3, M5 and M6, driven from outside the keyboard process. Physical iPhone only (the simulator has no
/// CoreBluetooth), and only against a Debug build of the Mac Receiver started with `-rkMeasureMode YES`, which turns the Mac's
/// measurement mode on and starts receiving. The Mac must be paired with this iPhone.
///
/// The host is this app's own home screen, the 測試輸入 field (`rk.home.testInput`); no other app is opened. Each test
/// switches to the Remote Keyboard through the globe key, puts it in Remote mode, opens the probe panel with a two-second
/// press on the status line, waits until the measurement page offers its button (the link is authenticated and the Mac
/// says `measure`), taps it and waits for the run to end. It types nothing.
///
/// Output: `RKMEAS <item> key=value ...` lines with counts and milliseconds, and the same lines attached as
/// `measure-<name>.txt`. Nothing the test or the keyboard prints holds typed text, a cursor position or a `dx`.
///
/// Settings travel as environment variables of the test run (`TEST_RUNNER_` prefix on the command line): RKMEAS_M3_SAMPLES
/// (default 10000), RKMEAS_M5_SAMPLES (default 3000), RKMEAS_M6_SCENARIO (normal, longText, load, covered or interference;
/// default normal) and RKMEAS_M6_SECONDS (default 600). Set the iPhone's auto-lock to Never first; M6 runs for minutes
/// without a touch.
@MainActor
final class MeasurementUITests: XCTestCase {
    private static let nextKeyboardNames = ["Next keyboard", "下一個鍵盤", "地球", "Globe", "下一個輸入法"]
    private static let remoteModeValue = "遠端"
    private static let settingNames = ["RKMEAS_M3_SAMPLES", "RKMEAS_M5_SAMPLES", "RKMEAS_M6_SCENARIO", "RKMEAS_M6_SECONDS"]
    private static let environment = ProcessInfo.processInfo.environment

    private var app: XCUIApplication!
    private var field: XCUIElement!
    private var printed: [String] = []
    private var attachmentName = "measure"

    override func setUp() async throws {
        continueAfterFailure = false
        printed = []
        app = XCUIApplication()
        for name in Self.settingNames {
            if let value = Self.environment[name] { app.launchEnvironment[name] = value }
        }
        app.launch()
        field = app.textFields["rk.home.testInput"]
    }

    override func tearDown() async throws {
        let attachment = XCTAttachment(string: printed.joined(separator: "\n") + "\n")
        attachment.name = "\(attachmentName).txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Tests

    /// M2: `updateValue` back-pressure with 41-byte and 182-byte packets, 100 rounds each.
    func testM2BackPressure() throws {
        try run(item: "M2", button: "rk.measure.m2", timeout: 300)
    }

    /// M3: application round trip at 60 Hz until RKMEAS_M3_SAMPLES replies (default 10,000) have arrived.
    func testM3RoundTrip() throws {
        let samples = Self.number("RKMEAS_M3_SAMPLES") ?? 10_000
        try run(item: "M3", button: "rk.measure.m3", timeout: TimeInterval(samples) / 15 + 180)
    }

    /// A short M3 (200 replies) to check that the chain works before the long run.
    func testM3Smoke() throws {
        try run(item: "M3smoke", button: "rk.measure.m3smoke", timeout: 120)
    }

    /// M5: M3 while a 3,000-character text goes out every second in the middle phase.
    func testM5Backlog() throws {
        let samples = Self.number("RKMEAS_M5_SAMPLES") ?? 3_000
        try run(item: "M5", button: "rk.measure.m5", timeout: TimeInterval(samples) / 15 + 180)
    }

    /// M6: a heartbeat every 100 ms for RKMEAS_M6_SECONDS (default 600) in the scenario RKMEAS_M6_SCENARIO. The Mac's side
    /// (gaps over 350 ms) is read from the Receiver's measurement summary and `measure-<date>.csv`.
    func testM6Heartbeat() throws {
        let seconds = Self.number("RKMEAS_M6_SECONDS") ?? 600
        try run(item: "M6", button: "rk.measure.m6", timeout: TimeInterval(seconds) + 180)
    }

    // MARK: Steps

    private static func number(_ name: String) -> Int? { environment[name].flatMap(Int.init) }

    private func run(item: String, button identifier: String, timeout: TimeInterval) throws {
        attachmentName = "measure-\(item)"
        try openOurKeyboardInRemoteMode()
        try openProbePanel(expecting: identifier)
        let button = element(identifier)
        XCTAssertTrue(wait(60) { button.exists && button.isEnabled }, "\(identifier) was not enabled: is the Mac in measurement mode and paired?")
        button.tap()
        let result = element("rk.measure.result")
        let finished = wait(timeout) {
            let text = result.label
            return text.hasPrefix("完成") || text.hasPrefix("中止")
        }
        let lines = result.label.split(separator: "\n").map(String.init)
        for line in lines.dropFirst() {
            let output = "RKMEAS \(line)"
            print(output)
            printed.append(output)
        }
        XCTAssertTrue(finished, "\(item) did not finish within \(Int(timeout)) s")
        XCTAssertEqual(lines.first, "完成", "\(item) ended early: \(lines.first ?? "no result")")
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The two-second press on the status line turns the probe panel on; a second press would turn it off again, so it
    /// is made only when neither the checklist nor the measurement page is showing.
    private func openProbePanel(expecting identifier: String) throws {
        let alreadyOn = element("rk.dictationProbe.line1").exists || element(identifier).exists
        if !alreadyOn {
            let status = element("rk.status")
            guard status.waitForExistence(timeout: 10) else { throw XCTSkip("the status line was not found: the keyboard is not in Remote mode") }
            status.press(forDuration: 2.5)
        }
        guard element(identifier).waitForExistence(timeout: 30) else {
            attachScreenshot("measure-page-missing")
            throw XCTSkip("the measurement page did not appear: the Mac's measurement mode is off or the link is not authenticated")
        }
    }

    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Focuses the field, switches to the Remote Keyboard with the globe key, then to Remote mode.
    private func openOurKeyboardInRemoteMode() throws {
        guard field.waitForExistence(timeout: 10) else { throw XCTSkip("the 測試輸入 field was not found") }
        field.tap()
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
            attachScreenshot("keyboard-not-reachable")
            throw XCTSkip("Remote Keyboard is not reachable from the globe key")
        }
        if (mode.value as? String) != Self.remoteModeValue {
            mode.tap()
            _ = wait(5) { (mode.value as? String) == Self.remoteModeValue }
        }
        guard (mode.value as? String) == Self.remoteModeValue else {
            throw XCTSkip("could not switch to Remote mode (Full Access must be on)")
        }
        // The probe panel sits over the English page's letter rows, so the keyboard has to be on that page.
        let zhEn = element("rk.zhEn")
        let onChinese = ["rk.hwDelete", "rk.quick.q"].contains { element($0).exists }
        if onChinese, zhEn.exists { zhEn.tap() }
    }

    /// The globe key: inside the keyboard, or in the system bar under it (where iPhones without a home button put it).
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

    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return condition()
    }
}
