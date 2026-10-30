import RemoteKeyboardCore
import XCTest

/// T06 reconnect gate, driven from outside the keyboard process.
///
/// Run on a physical iPhone only, with the Mac Receiver already armed (press 開始接收 on the Mac first) and
/// "Remote Keyboard" already selected as the current keyboard, Full Access on and the Mac paired. The keyboard's mode
/// does not matter: the warm-up taps the `rk.mode` toggle once if the keyboard is in Local mode, and the saved
/// Remote mode then holds for every counted reopen (the status line, `rk.status`, is hidden in Local mode).
///
/// Gate evidence is the attached `reconnect-ui.csv`. The gate metric is keyboard visible to connected
/// (`keyboardToConnectedMs`, P95 at most 2000 ms, and at least 99 of 100 reopens connected). It starts at the first
/// time `rk.status` exists, not at the tap, because the XCUITest `tap()` call alone costs about 0.7 s in Notes and
/// 1.8 s in Safari and is not part of the product. `latencyMs` (tap to connected) and the `RKTIMING` lines stay in
/// the file for reference. The Mac's `reconnect.csv` (iPhone-measured keyboard appear to connected) is the
/// cross-check.
///
/// Before running, start with Notes closed or sitting on the notes list. The test creates one new note for itself
/// and taps only inside that note's body; it never touches an existing note. In Safari it taps only the address bar,
/// never page content. The test types nothing: a tap is only what makes the keyboard appear (plus the one mode-toggle tap above).
///
/// A warm-up (not counted) checks that the keyboard is reachable and selects it. The counted reopens start after it.
/// Whatever was measured is attached to the result even when the test fails part way.
@MainActor
final class ReconnectUITests: XCTestCase {
    private static let notesID = "com.apple.mobilenotes"
    private static let safariID = "com.apple.mobilesafari"
    private static let apps = [notesID, safariID]
    private static let statusIdentifier = "rk.status"
    private static let modeIdentifier = "rk.mode"
    /// The `rk.mode` toggle's accessibility value while the keyboard is in Local mode.
    private static let localModeValue = "本機"
    private static let connectTimeoutSeconds = 10.0
    private static let defaultCount = 100

    /// All times come from the test runner's own monotonic clock, so they can be subtracted from one another.
    private struct Row {
        let index: Int
        let bundleID: String
        /// Just before `tap()`; this is the gate's `shownAt`.
        let tapStartMs: Int64
        /// Right after `tap()` returned.
        let tapReturnMs: Int64
        /// First time an existence check on `rk.status` came back true (includes that query's own duration).
        let keyboardVisibleMs: Int64?
        let connectedMs: Int64?

        var sample: ReconnectSample { ReconnectSample(shownAtMs: tapStartMs, connectedAtMs: connectedMs) }
        var tapDuration: Int64 { tapReturnMs - tapStartMs }
        var tapToKeyboard: Int64? { keyboardVisibleMs.map { $0 - tapReturnMs } }
        var keyboardToConnected: Int64? {
            guard let keyboardVisibleMs, let connectedMs else { return nil }
            return connectedMs - keyboardVisibleMs
        }
    }

    /// Kept on the instance so `tearDown` can attach whatever was measured, even after a failure.
    private var rows: [Row] = []

    override func setUp() async throws {
        continueAfterFailure = false
        rows = []
    }

    override func tearDown() async throws {
        if !rows.isEmpty { attach(rows) }
    }

    func testHundredReopens() throws {
        // TEST_RUNNER_RK_REOPEN_COUNT=3 gives a short dry run; the gate itself is the default 100.
        let count = ProcessInfo.processInfo.environment["RK_REOPEN_COUNT"].flatMap(Int.init) ?? Self.defaultCount

        try warmUp()

        for index in 0..<count {
            let bundleID = Self.apps[index % Self.apps.count]
            let app = XCUIApplication(bundleIdentifier: bundleID)
            app.activate()
            guard let target = tapTarget(in: app, bundleID: bundleID) else {
                XCTFail("no safe tap target in \(bundleID) at reopen \(index + 1)")
                break
            }
            // Taken immediately before the tap that brings the keyboard up.
            let tapStart = Self.nowMs()
            target.tap()
            let tapReturn = Self.nowMs()
            let observed = observeKeyboard(statusElement(in: app), tapStart: tapStart)
            rows.append(Row(
                index: index + 1, bundleID: bundleID, tapStartMs: tapStart, tapReturnMs: tapReturn,
                keyboardVisibleMs: observed.visible, connectedMs: observed.connected))
            hideKeyboard(in: app)
        }

        let summary = ReconnectStats.summarize(rows.map(\.sample))
        XCTAssertEqual(summary.attempts, count)
        // At least 99 of 100 connected (scaled for dry runs); a reopen whose keyboard never appeared counts as failed.
        XCTAssertGreaterThanOrEqual(summary.successes * 100, summary.attempts * 99, "connected \(summary.successes)/\(summary.attempts)")
        // P95 of keyboard visible to connected at most 2000 ms (the user's ruling of 2026-10-30).
        let fromKeyboard = ReconnectStats.summarize(rows.compactMap { row in
            row.keyboardVisibleMs.map { ReconnectSample(shownAtMs: $0, connectedAtMs: row.connectedMs) }
        })
        XCTAssertLessThanOrEqual(
            fromKeyboard.p95Ms ?? .max, 2000, "keyboard-to-connected P95 \(fromKeyboard.p95Ms.map(String.init) ?? "n/a") ms")
    }

    // MARK: Label probe

    /// Read-only: launches Notes and Safari and prints control identifiers and labels, prefixed `RKPROBE`, so the
    /// real localized names can be read off a device. It never taps, never types and never reads `value`. It does not
    /// look at static texts or cells (they hold note titles); buttons that sit inside a cell are left out too.
    func testProbeLabels() {
        var lines: [String] = []
        func record(_ line: String) {
            lines.append("RKPROBE " + line)
            print("RKPROBE " + line)
        }
        func dump(_ title: String, _ query: XCUIElementQuery, skip: Set<String> = [], onlyWithIdentifier: Bool = false,
                  identifierContains: [String] = []) {
            for element in query.allElementsBoundByIndex.prefix(60) {
                let id = element.identifier
                let label = element.label
                if onlyWithIdentifier, id.isEmpty { continue }
                if !identifierContains.isEmpty, !identifierContains.contains(where: { id.contains($0) }) { continue }
                if skip.contains(id + "\u{1}" + label) { continue }
                record("\(title) id=[\(id)] label=[\(label)]")
            }
        }

        let notes = XCUIApplication(bundleIdentifier: Self.notesID)
        notes.activate()
        _ = notes.buttons.firstMatch.waitForExistence(timeout: 5)
        record("app=notes")
        // Buttons nested in list rows can carry note titles, so they are excluded.
        var inCells: Set<String> = []
        for button in notes.cells.descendants(matching: .button).allElementsBoundByIndex.prefix(200) {
            inCells.insert(button.identifier + "\u{1}" + button.label)
        }
        dump("notes.toolbars.buttons", notes.toolbars.buttons, skip: inCells)
        dump("notes.navigationBars.buttons", notes.navigationBars.buttons, skip: inCells)
        dump("notes.buttons(id)", notes.buttons, skip: inCells, onlyWithIdentifier: true)

        let safari = XCUIApplication(bundleIdentifier: Self.safariID)
        safari.activate()
        _ = safari.buttons.firstMatch.waitForExistence(timeout: 5)
        record("app=safari")
        dump("safari.textFields", safari.textFields)
        dump("safari.buttons(URL|Address|TabBar)", safari.buttons, identifierContains: ["URL", "Address", "TabBar"])
        dump("safari.toolbars.buttons", safari.toolbars.buttons)

        let attachment = XCTAttachment(string: lines.joined(separator: "\n") + "\n")
        attachment.name = "rkprobe.txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Warm-up (not counted)

    /// Creates the test's own note, proves the keyboard is reachable (O6, trying the globe a few times), lets the link
    /// settle, and checks Safari's address bar. None of this is a counted sample.
    private func warmUp() throws {
        let notes = XCUIApplication(bundleIdentifier: Self.notesID)
        notes.activate()
        let newNote = Self.firstMatch(
            in: notes, queries: [notes.buttons], identifiers: Self.newNoteIdentifiers, labels: Self.newNoteLabels, timeout: 5)
        guard let newNote else {
            throw XCTSkip("Notes: new-note button not found; start with Notes closed or on the notes list")
        }
        newNote.tap()
        let body = notes.textViews.firstMatch
        guard body.waitForExistence(timeout: 5) else { throw XCTSkip("Notes: the new note's body did not appear") }
        // Only an empty body is ever tapped, so an existing note can never be touched.
        guard Self.isEmpty(body) else {
            XCTFail("no safe tap target: the Notes body is not empty")
            return
        }
        body.tap()

        // The status line is hidden in Local mode, so reachability is judged by the mode toggle, which is always there.
        let mode = notes.descendants(matching: .any).matching(identifier: Self.modeIdentifier).firstMatch
        var found = mode.waitForExistence(timeout: Self.connectTimeoutSeconds)
        var tries = 0
        while !found && tries < 6 {
            tries += 1
            let next = notes.keyboards.buttons["Next keyboard"]
            guard next.exists else { break }
            next.tap()
            found = mode.waitForExistence(timeout: 2)
        }
        guard found else { throw XCTSkip("O6: third-party keyboard not reachable") }
        // The saved mode persists across reopens, so one tap here puts every counted reopen in Remote mode.
        if (mode.value as? String) == Self.localModeValue { mode.tap() }
        let status = statusElement(in: notes)
        guard status.waitForExistence(timeout: Self.connectTimeoutSeconds) else {
            XCTFail("rk.status did not appear in Remote mode (is Full Access on?)")
            return
        }
        guard waitForConnected(status, shownAt: Self.nowMs()) != nil else {
            XCTFail("warm-up never connected")
            return
        }
        hideKeyboard(in: notes)

        let safari = XCUIApplication(bundleIdentifier: Self.safariID)
        safari.activate()
        guard let bar = addressBar(in: safari) else { throw XCTSkip("Safari: address bar not found") }
        bar.tap()
        hideKeyboard(in: safari)
    }

    // MARK: Steps

    private func statusElement(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: Self.statusIdentifier).firstMatch
    }

    /// What may be tapped to raise the keyboard: the warm-up's note body in Notes, the address bar in Safari.
    private func tapTarget(in app: XCUIApplication, bundleID: String) -> XCUIElement? {
        let element = bundleID == Self.notesID ? app.textViews.firstMatch : addressBar(in: app)
        guard let element, element.waitForExistence(timeout: 5) else { return nil }
        // The note body is tapped only while it is empty (it is the test's own, never typed into).
        if bundleID == Self.notesID, !Self.isEmpty(element) { return nil }
        return element
    }

    private static func isEmpty(_ element: XCUIElement) -> Bool {
        (element.value as? String ?? "").isEmpty
    }

    /// Safari's address bar is a field when editing and a button otherwise. Matched by identifier first, then by
    /// English and Traditional Chinese labels. Only text fields and buttons are searched, never page content.
    private func addressBar(in app: XCUIApplication) -> XCUIElement? {
        Self.firstMatch(
            in: app, queries: [app.textFields, app.buttons],
            identifiers: Self.addressIdentifiers, labels: Self.addressLabels, timeout: 5)
    }

    // MARK: Locale-proof lookup

    private static let newNoteIdentifiers = ["New Note", "Compose", "newNoteButton"]
    private static let newNoteLabels = ["New Note", "Compose", "新增備忘錄", "新備忘錄", "撰寫"]
    private static let addressIdentifiers = ["URL", "Address", "TabBarItemTitle"]
    private static let addressLabels = ["Address", "URL", "地址", "網址", "搜尋或輸入網址", "搜尋或輸入網站名稱"]
    private static let dismissNames = ["Done", "Cancel", "Hide keyboard", "完成", "取消", "隱藏鍵盤"]

    /// Polls until an element matches: every identifier first (in order), then every exact label, across `queries`.
    private static func firstMatch(
        in app: XCUIApplication, queries: [XCUIElementQuery], identifiers: [String], labels: [String], timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for id in identifiers {
                for query in queries {
                    let element = query.matching(identifier: id).firstMatch
                    if element.exists { return element }
                }
            }
            for label in labels {
                for query in queries {
                    let element = query.matching(NSPredicate(format: "label == %@", label)).firstMatch
                    if element.exists { return element }
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }

    /// Polls until the status label's value is `connected`, or the timeout. `nil` means it never connected.
    private func waitForConnected(_ status: XCUIElement, shownAt: Int64) -> Int64? {
        let deadline = shownAt + Int64(Self.connectTimeoutSeconds * 1000)
        while Self.nowMs() < deadline {
            if status.exists, (status.value as? String) == "connected" { return Self.nowMs() }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }

    /// One loop, no sleeps: each pass is a single existence check (which is itself the pacing), and the value is read
    /// only once the element exists. `visible` is the first pass where it existed; `connected` the first where its
    /// value was `connected`. Gives up after the connect timeout, counted from the start of the tap.
    private func observeKeyboard(_ status: XCUIElement, tapStart: Int64) -> (visible: Int64?, connected: Int64?) {
        let deadline = tapStart + Int64(Self.connectTimeoutSeconds * 1000)
        var visible: Int64?
        while Self.nowMs() < deadline {
            guard status.exists else { continue }
            if visible == nil { visible = Self.nowMs() }
            if (status.value as? String) == "connected" { return (visible, Self.nowMs()) }
        }
        return (visible, nil)
    }

    private func hideKeyboard(in app: XCUIApplication) {
        for name in Self.dismissNames {
            let button = app.buttons[name].firstMatch
            if button.exists, button.isHittable {
                button.tap()
                break
            }
        }
        // Switching to the other app on the next reopen also dismisses this keyboard, so a missing button is fine.
        let gone = app.descendants(matching: .any).matching(identifier: Self.statusIdentifier).firstMatch
        _ = gone.waitForNonExistence(timeout: 2)
    }

    private func attach(_ rows: [Row]) {
        func cell(_ value: Int64?) -> String { value.map(String.init) ?? "" }
        var csv = "index,app,tapStartMs,tapReturnMs,keyboardVisibleMs,connectedMs,latencyMs,keyboardToConnectedMs,result\n"
        for row in rows {
            let latency = row.connectedMs.map { $0 - row.tapStartMs }
            csv += "\(row.index),\(row.bundleID),\(row.tapStartMs),\(row.tapReturnMs),\(cell(row.keyboardVisibleMs)),"
                + "\(cell(row.connectedMs)),\(cell(latency)),\(cell(row.keyboardToConnected)),"
                + "\(row.connectedMs == nil ? "timeout" : "connected")\n"
        }
        let summary = ReconnectStats.summarize(rows.map(\.sample))
        csv += "# attempts=\(summary.attempts) successes=\(summary.successes) p95Ms=\(summary.p95Ms.map(String.init) ?? "n/a")\n"
        let timing = timingLines(rows)
        timing.forEach { print($0) }
        csv += timing.map { "# " + $0 }.joined(separator: "\n") + "\n"
        let attachment = XCTAttachment(string: csv)
        attachment.name = "reconnect-ui.csv"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// `RKTIMING` lines: P95 and median of each interval, per app. Nearest rank, like `ReconnectStats`.
    private func timingLines(_ rows: [Row]) -> [String] {
        func rank(_ values: [Int64], _ percent: Int) -> Int64? {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return nil }
            return sorted[(percent * sorted.count + 99) / 100 - 1]
        }
        let metrics: [(String, (Row) -> Int64?)] = [
            ("tapReturn-tapStart", { $0.tapDuration }),
            ("keyboardVisible-tapReturn", { $0.tapToKeyboard }),
            ("keyboardToConnected", { $0.keyboardToConnected })
        ]
        var lines: [String] = []
        for app in Self.apps {
            let own = rows.filter { $0.bundleID == app }
            for (name, value) in metrics {
                let values = own.compactMap(value)
                let p95 = rank(values, 95).map(String.init) ?? "n/a"
                let median = rank(values, 50).map(String.init) ?? "n/a"
                lines.append("RKTIMING app=\(app) metric=\(name) n=\(values.count)/\(own.count) p95=\(p95) median=\(median)")
            }
        }
        return lines
    }

    private static func nowMs() -> Int64 { MonotonicClock.nowMs() }
}
