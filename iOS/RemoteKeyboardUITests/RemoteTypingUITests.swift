import XCTest

/// Types a fixed line through Remote Keyboard to whichever computer is current, for the receiver e2e scripts.
///
/// Run on a physical iPhone with the computer paired and current, and a text editor focused on the computer. The test
/// opens a new note in Notes (it never touches existing notes), picks Remote Keyboard from the globe menu if needed,
/// switches to Remote and 即時 mode, then types `hello`, space, `world`, one Backspace, `d` and Return, so the computer
/// should receive "hello world" and a line break. It prints `RKTYPE sent` when done; the computer side is checked by
/// the script that started it.
@MainActor
final class RemoteTypingUITests: XCTestCase {
    private let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")

    func testTypeHelloWorld() throws {
        notes.activate()
        let newNote = notes.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", "新增備忘錄", "Compose")).firstMatch
        if newNote.waitForExistence(timeout: 5) { newNote.tap() }
        let body = notes.textViews.firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5), "no note body")
        if (body.value as? String ?? "").isEmpty { body.tap() }
        try ensureRemoteKeyboard()
        let mode = element("rk.mode")
        if (mode.value as? String) == "本機" { mode.tap() }
        let status = element("rk.status")
        XCTAssertTrue(wait(15) { (status.value as? String) == "connected" }, "not connected: \(status.label) \(String(describing: status.value))")
        if !key("a").exists { element("rk.zhEn").tap() }
        XCTAssertTrue(key("a").waitForExistence(timeout: 5), "English page not shown")
        type("hello"); element("rk.space").tap(); type("world")
        element("rk.backspace").tap()
        type("d"); element("rk.return").tap()
        sleep(2)
        print("RKTYPE sent")
    }

    private func ensureRemoteKeyboard() throws {
        if element("rk.mode").waitForExistence(timeout: 3) { return }
        let globe = notes.buttons.matching(NSPredicate(format: "label == %@", "下一個鍵盤")).firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 5), "no globe key")
        globe.press(forDuration: 1.2)
        let item = notes.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Remote Keyboard")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), "Remote Keyboard not in the globe menu")
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(element("rk.mode").waitForExistence(timeout: 10), "Remote Keyboard did not appear")
    }

    private func element(_ id: String) -> XCUIElement { notes.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func key(_ label: String) -> XCUIElement {
        notes.descendants(matching: .button).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
    private func type(_ text: String) {
        for c in text { let k = key(String(c)); XCTAssertTrue(k.waitForExistence(timeout: 5), "key \(c)"); k.tap() }
    }
    private func wait(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; usleep(200_000) }
        return condition()
    }
}
