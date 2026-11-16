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

    /// Timing run (e2e/scripts/measure-trackpad.sh): `RK_STROKE_COUNT` fixed strokes (default 20) across the pad at mid height, alternating
    /// left to right and right to left (normalized x 0.15 and 0.85) and cycling slow, default and fast velocity, 0.8 s apart so the
    /// receiver sees every stroke end after its 300 ms idle. No tap, click or scroll. With `RK_EXPECT_PATH=wifi` it first waits up to
    /// 5 s for the pad's label to say Wi-Fi; without it nothing waits. Prints only
    /// `RKTP strokes=<N> start=<ISO8601 UTC ms> end=<ISO8601 UTC ms> path_start=<wifi|bluetooth> path_end=<wifi|bluetooth>`
    /// (the path the pad's label shows at the start and the end): no position, distance or text.
    func testFixedStrokes() throws {
        let asked = Int(ProcessInfo.processInfo.environment["RK_STROKE_COUNT"] ?? "") ?? 20
        let count = asked > 0 ? asked : 20
        try openOurKeyboardInRemoteMode()
        let key = element("rk.trackpad.toggle")
        guard key.waitForExistence(timeout: 15), wait(15, until: { key.isEnabled }) else {
            attach("trackpad-key-missing")
            throw XCTSkip("the 觸控板 key did not become usable (Mac not connected?)")
        }
        key.tap()

        let pad = element("rk.trackpad.state")
        guard pad.waitForExistence(timeout: 5) else { return XCTFail("the pad did not appear") }
        let ready = wait(10) { (pad.value as? String) == Self.readyValue }
        attach("trackpad-state")
        guard ready else { return XCTFail("the pad never reported ready") }
        if ProcessInfo.processInfo.environment["RK_EXPECT_PATH"] == "wifi" {
            _ = wait(5) { pad.label.contains("Wi-Fi") }
        }
        let pathStart = path(of: pad)

        let velocities: [XCUIGestureVelocity] = [.slow, .default, .fast]
        let left = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
        let right = pad.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")

        let start = formatter.string(from: Date())
        for index in 0..<count {
            let from = index % 2 == 0 ? left : right
            let to = index % 2 == 0 ? right : left
            from.press(forDuration: 0.05, thenDragTo: to, withVelocity: velocities[index % velocities.count], thenHoldForDuration: 0)
            Thread.sleep(forTimeInterval: 0.8)
        }
        let end = formatter.string(from: Date())
        print("RKTP strokes=\(count) start=\(start) end=\(end) path_start=\(pathStart) path_end=\(path(of: pad))")
    }

    /// Timing run with sudden turns (`RK_STROKE_PATTERN=turns` in e2e/scripts/measure-trackpad.sh): `RK_STROKE_COUNT` strokes (default 20), each
    /// one continuous finger-down path of 20 segments of 0.1 s that goes up, down, left or right by 40 pt (400 pt/s) at random and
    /// starts at the pad centre; a direction that would leave the inner 10%...90% box turns around. Stroke i uses seed `RK_TURN_SEED`
    /// (default 1) plus i, so the same seed draws the same paths on Bluetooth and Wi-Fi. Strokes are 0.8 s apart. The stroke is sent as
    /// one synthesized touch path (private XCTest event synthesis, see TouchSynthesizer.m); if that is unavailable the test fails.
    /// Prints the same line as testFixedStrokes plus ` pattern=turns seed=<seed>`: no position, distance or text.
    func testTurnStrokes() throws {
        let environment = ProcessInfo.processInfo.environment
        let asked = Int(environment["RK_STROKE_COUNT"] ?? "") ?? 20
        let count = asked > 0 ? asked : 20
        let seed = UInt64(environment["RK_TURN_SEED"] ?? "") ?? 1
        try openOurKeyboardInRemoteMode()
        let key = element("rk.trackpad.toggle")
        guard key.waitForExistence(timeout: 15), wait(15, until: { key.isEnabled }) else {
            attach("trackpad-key-missing")
            throw XCTSkip("the 觸控板 key did not become usable (Mac not connected?)")
        }
        key.tap()

        let pad = element("rk.trackpad.state")
        guard pad.waitForExistence(timeout: 5) else { return XCTFail("the pad did not appear") }
        let ready = wait(10) { (pad.value as? String) == Self.readyValue }
        attach("trackpad-state")
        guard ready else { return XCTFail("the pad never reported ready") }
        if environment["RK_EXPECT_PATH"] == "wifi" {
            _ = wait(5) { pad.label.contains("Wi-Fi") }
        }
        let pathStart = path(of: pad)

        let frame = pad.frame
        let box = frame.insetBy(dx: frame.width * 0.1, dy: frame.height * 0.1)
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")

        let start = formatter.string(from: Date())
        for index in 0..<count {
            let ends = TurnPath.make(seed: seed &+ UInt64(index), segments: 20, segmentLength: 40, box: box, start: centre)
            let samples = TurnPath.samples(start: centre, ends: ends, segmentDuration: 0.1)
            do {
                try RKTouchSynthesizer.drag(through: samples.points.map { NSValue(cgPoint: $0) },
                                            offsets: samples.offsets.map { NSNumber(value: $0) })
            } catch {
                return XCTFail("touch synthesis failed at stroke \(index + 1): \(error.localizedDescription)")
            }
            Thread.sleep(forTimeInterval: 0.8)
        }
        let end = formatter.string(from: Date())
        print("RKTP strokes=\(count) start=\(start) end=\(end) path_start=\(pathStart) path_end=\(path(of: pad)) pattern=turns seed=\(seed)")
    }

    // MARK: Steps

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// `wifi` when the pad's label (「觸控板，Wi-Fi」 or 「觸控板，藍牙」) names Wi-Fi, otherwise `bluetooth`.
    private func path(of pad: XCUIElement) -> String {
        pad.label.contains("Wi-Fi") ? "wifi" : "bluetooth"
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
