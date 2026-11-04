import XCTest

/// Device smoke for the touchpad page (main agent runs it; needs the Mac Receiver paired, receiving, with 「允許觸控板控制」 on).
///
/// It opens the Remote Keyboard from the 測試輸入 field with the globe key, switches to Remote, waits for the 觸控板 key to be enabled, taps it,
/// waits until the pad reports `ready` (`rk.trackpad.state`) and then makes one slow horizontal drag across it (the finger moves at
/// once: no tap, no long press). No click, no long press and no scroll. It prints only `RKTP state=ready swiped=1`: no position,
/// no distance and no text.
@MainActor
final class TrackpadSmokeUITests: XCTestCase {
    private static let nextKeyboardNames = ["Next keyboard", "下一個鍵盤", "地球", "Globe", "下一個輸入法"]
    private static let remoteModeValue = "遠端"
    private static let readyValue = "ready"

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchAtTestInput()
    }

    func testPadReportsReadyAndTakesASlowSwipe() throws {
        try openOurKeyboardInRemoteMode()
        let key = element("rk.trackpad.toggle")
        // The key is always on the keyboard; it is usable (enabled) only once the Remote link is connected.
        guard key.waitForExistence(timeout: 15), wait(15, until: { key.isEnabled }) else {
            attach("trackpad-key-missing")
            throw XCTSkip("the 觸控板 key did not become usable (Mac not connected?)")
        }
        key.tap()

        let pad = element("rk.trackpad.state")
        guard pad.waitForExistence(timeout: 5) else { return XCTFail("the pad did not appear") }
        let ready = wait(10) { (pad.value as? String) == Self.readyValue }
        attach("trackpad-state")
        guard ready else {
            print("RKTP state=\(pad.value as? String ?? "unknown") swiped=0")
            return XCTFail("the pad never reported ready")
        }

        // One slow horizontal drag from the left third to the right third at mid height: the press starts moving at once.
        let start = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5))
        let end = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        print("RKTP state=ready swiped=1")
    }

    // MARK: Steps

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openOurKeyboardInRemoteMode() throws {
        let field = app.textFields["rk.home.testInput"]
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
            attach("keyboard-not-reachable")
            throw XCTSkip("Remote Keyboard is not reachable from the globe key")
        }
        if (mode.value as? String) != Self.remoteModeValue {
            mode.tap()
            _ = wait(5) { (mode.value as? String) == Self.remoteModeValue }
        }
        guard (mode.value as? String) == Self.remoteModeValue else { throw XCTSkip("could not switch to Remote mode") }
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

    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return condition()
    }
}
