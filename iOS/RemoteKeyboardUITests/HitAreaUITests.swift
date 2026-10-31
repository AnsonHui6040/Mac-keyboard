import XCTest

/// D24 hit area: a touch in the empty space between keys, between rows, beside the key area and under the bottom row
/// must type the nearest key. Driven from outside the keyboard process.
///
/// The host is this app's own home screen, the 測試輸入 field (`rk.home.testInput`); no other app is opened. The test
/// switches to the Remote Keyboard through the globe key, puts it in Local mode (the text goes straight into the field,
/// no Mac or Bluetooth needed) and on the English page, then taps points that lie in gaps and reads the field after
/// each tap. It types only its own letters and a space, removes them again at the end, and never prints the field's
/// text: the log has the item number and PASS or FAIL only.
///
/// Run on a physical iPhone (or a simulator whose keyboard list contains Remote Keyboard) with the app installed:
/// `-only-testing:RemoteKeyboardUITests/HitAreaUITests`. The keyboard must be allowed to open (the globe key switches to it).
@MainActor
final class HitAreaUITests: XCTestCase {
    private static let nextKeyboardNames = ["Next keyboard", "下一個鍵盤", "地球", "Globe", "下一個輸入法"]
    private static let localModeValue = "本機"
    private static let placeholder = "在這裡輸入"

    private var app: XCUIApplication!
    private var field: XCUIElement!
    private var results: [String] = []
    /// How many characters this test added to the field; they are deleted again at the end.
    private var typed = 0

    override func setUp() async throws {
        continueAfterFailure = true
        results = []
        typed = 0
        app = XCUIApplication()
        app.launch()
        field = app.textFields["rk.home.testInput"]
    }

    override func tearDown() async throws {
        removeTypedText()
        let attachment = XCTAttachment(string: results.joined(separator: "\n") + "\n")
        attachment.name = "hit-area.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testGapsTypeTheNearestKey() throws {
        try openOurKeyboardInLocalMode()

        let q = try key("q"), w = try key("w"), a = try key("a"), l = try key("l"), p = try key("p")
        let space = try identified("rk.space")
        let screen = app.frame
        let gapQW = w.frame.minX - q.frame.maxX
        XCTAssertGreaterThan(gapQW, 2, "q and w have a gap to tap in")

        // 0: control, the middle of q. If this fails the test setup is wrong, not the hit area.
        check(0, at: CGPoint(x: q.frame.midX, y: q.frame.midY), expects: "q")
        // 1: in the gap between q and w, closer to q.
        check(1, at: CGPoint(x: q.frame.maxX + gapQW * 0.25, y: q.frame.midY), expects: "q")
        // 2: in the gap between q and w, closer to w.
        check(2, at: CGPoint(x: w.frame.minX - gapQW * 0.25, y: q.frame.midY), expects: "w")
        // 3: between row 1 and row 2, over a's left part, 2 pt under row 1: row 1 (q is above this x).
        check(3, at: CGPoint(x: a.frame.minX + 2, y: q.frame.maxY + 2), expects: "q")
        // 4: the same x, 2 pt above row 2: row 2 (a).
        check(4, at: CGPoint(x: a.frame.minX + 2, y: a.frame.minY - 2), expects: "a")
        // 5: left of a, beside the indented second row.
        check(5, at: CGPoint(x: a.frame.minX - 6, y: a.frame.midY), expects: "a")
        // 6: the very left edge of the keyboard, level with a.
        check(6, at: CGPoint(x: screen.minX + 3, y: a.frame.midY), expects: "a")
        // 7: right of l, beside the indented second row.
        check(7, at: CGPoint(x: l.frame.maxX + 6, y: l.frame.midY), expects: "l")
        // 8: the very right edge of the keyboard, level with l.
        check(8, at: CGPoint(x: screen.maxX - 3, y: l.frame.midY), expects: "l")
        // 9: right of p, at the very right edge of row 1.
        check(9, at: CGPoint(x: screen.maxX - 3, y: p.frame.midY), expects: "p")
        // 10: between the last letter row and the bottom row, 2 pt above the space key.
        check(10, at: CGPoint(x: space.frame.midX, y: space.frame.minY - 2), expects: " ")
        // 11: in the gap on the right of space (the return key is on its right), closer to space.
        check(11, at: CGPoint(x: space.frame.maxX + 1.5, y: space.frame.midY), expects: " ")
        // 12: under the bottom row, still inside the keyboard.
        check(12, at: CGPoint(x: space.frame.midX, y: space.frame.maxY + 2), expects: " ")

        let failed = results.filter { $0.hasSuffix("FAIL") }
        XCTAssertTrue(failed.isEmpty, "\(failed.count) of \(results.count) items failed")
    }

    // MARK: Steps

    /// Taps the point and compares the field with the text before plus `expects`. The log has no text.
    private func check(_ item: Int, at point: CGPoint, expects character: String) {
        let before = fieldText()
        tap(point)
        let expected = before + character
        let deadline = Date().addingTimeInterval(1.5)
        var after = fieldText()
        while after == before, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
            after = fieldText()
        }
        if after.count > before.count { typed += after.count - before.count }
        let pass = after == expected
        let line = "RKHIT item \(item) \(pass ? "PASS" : "FAIL")"
        print(line)
        results.append(line)
        XCTAssertTrue(pass, "item \(item)")
    }

    private func attachScreenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func tap(_ point: CGPoint) {
        let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
        origin.withOffset(CGVector(dx: point.x, dy: point.y)).tap()
    }

    /// The field's text; the placeholder is what `value` reports while it is empty.
    private func fieldText() -> String {
        let value = field.value as? String ?? ""
        return value == Self.placeholder ? "" : value
    }

    private func key(_ letter: String) throws -> XCUIElement {
        let found = app.descendants(matching: .button).matching(NSPredicate(format: "label == %@", letter)).firstMatch
        guard found.waitForExistence(timeout: 5) else {
            attachScreenshot("key-not-found")
            throw XCTSkip("key \(letter) not found")
        }
        return found
    }

    private func identified(_ identifier: String) throws -> XCUIElement {
        let found = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        guard found.waitForExistence(timeout: 5) else { throw XCTSkip("\(identifier) not found") }
        return found
    }

    /// Focuses the field, switches to the Remote Keyboard with the globe key, then Local mode and the English page.
    private func openOurKeyboardInLocalMode() throws {
        guard field.waitForExistence(timeout: 10) else { throw XCTSkip("the 測試輸入 field was not found") }
        field.tap()
        let mode = app.descendants(matching: .any).matching(identifier: "rk.mode").firstMatch
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
        if (mode.value as? String) != Self.localModeValue {
            mode.tap()
            _ = wait(5) { (mode.value as? String) == Self.localModeValue }
        }
        guard (mode.value as? String) == Self.localModeValue else { throw XCTSkip("could not switch to Local mode") }
        let zhEn = app.descendants(matching: .any).matching(identifier: "rk.zhEn").firstMatch
        // The keyboard may open on the Chinese page (handwriting or Quick); 中英 goes back to the English letters.
        let onChinese = ["rk.hwDelete", "rk.quick.q"].contains {
            app.descendants(matching: .any).matching(identifier: $0).firstMatch.exists
        }
        if onChinese, zhEn.exists { zhEn.tap() }
        _ = try key("q")
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

    private func removeTypedText() {
        let backspace = app.descendants(matching: .any).matching(identifier: "rk.backspace").firstMatch
        guard typed > 0, backspace.exists else { return }
        for _ in 0..<typed { backspace.tap() }
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
