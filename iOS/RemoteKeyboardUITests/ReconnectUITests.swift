import RemoteKeyboardCore
import XCTest

/// T06 reconnect gate, driven from outside the keyboard process.
///
/// Run on a physical iPhone only, with the Mac Receiver already armed (press 開始接收 on the Mac first) and
/// "Remote Keyboard" already selected as the current keyboard. The Mac's `reconnect.csv` is the authoritative
/// record; this test's own numbers include XCUITest query latency and are only a cross-check.
///
/// Before running, start with Notes closed or sitting on the notes list. The test creates one new note for itself
/// and taps only inside that note's body; it never touches an existing note. In Safari it taps only the address bar,
/// never page content. The test types nothing: a tap is only what makes the keyboard appear.
///
/// A warm-up (not counted) checks that the keyboard is reachable and selects it. The counted reopens start after it.
/// Whatever was measured is attached to the result even when the test fails part way.
@MainActor
final class ReconnectUITests: XCTestCase {
    private static let notesID = "com.apple.mobilenotes"
    private static let safariID = "com.apple.mobilesafari"
    private static let apps = [notesID, safariID]
    private static let statusIdentifier = "rk.status"
    private static let connectTimeoutSeconds = 10.0
    private static let defaultCount = 100

    private struct Row {
        let index: Int
        let bundleID: String
        let sample: ReconnectSample
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
            let shownAt = Self.nowMs()
            target.tap()
            let status = statusElement(in: app)
            let connectedAt = waitForConnected(status, shownAt: shownAt)
            rows.append(Row(index: index + 1, bundleID: bundleID, sample: ReconnectSample(shownAtMs: shownAt, connectedAtMs: connectedAt)))
            hideKeyboard(in: app)
        }

        let summary = ReconnectStats.summarize(rows.map(\.sample))
        XCTAssertEqual(summary.attempts, count)
        // At least 99 of 100 connected (scaled for dry runs) and P95 at most 2000 ms.
        XCTAssertGreaterThanOrEqual(summary.successes * 100, summary.attempts * 99, "connected \(summary.successes)/\(summary.attempts)")
        XCTAssertLessThanOrEqual(summary.p95Ms ?? .max, 2000, "P95 \(summary.p95Ms.map(String.init) ?? "n/a") ms")
    }

    // MARK: Warm-up (not counted)

    /// Creates the test's own note, proves the keyboard is reachable (O6, trying the globe a few times), lets the link
    /// settle, and checks Safari's address bar. None of this is a counted sample.
    private func warmUp() throws {
        let notes = XCUIApplication(bundleIdentifier: Self.notesID)
        notes.activate()
        let newNote = ["New Note", "Compose"].lazy.map { notes.buttons[$0] }.first { $0.waitForExistence(timeout: 3) }
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

        let status = statusElement(in: notes)
        var found = status.waitForExistence(timeout: Self.connectTimeoutSeconds)
        var tries = 0
        while !found && tries < 6 {
            tries += 1
            let next = notes.keyboards.buttons["Next keyboard"]
            guard next.exists else { break }
            next.tap()
            found = status.waitForExistence(timeout: 2)
        }
        guard found else { throw XCTSkip("O6: third-party keyboard not reachable") }
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

    /// Safari's address bar is a field when editing and a button otherwise. Page content is never a candidate.
    private func addressBar(in app: XCUIApplication) -> XCUIElement? {
        let candidates = [app.textFields["Address"], app.buttons["Address"], app.buttons["URL"]]
        return candidates.first { $0.waitForExistence(timeout: 3) }
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

    private func hideKeyboard(in app: XCUIApplication) {
        for name in ["Done", "Cancel", "Hide keyboard"] {
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
        var csv = "index,app,shownAtMs,connectedAtMs,latencyMs,result\n"
        for row in rows {
            if let connected = row.sample.connectedAtMs {
                csv += "\(row.index),\(row.bundleID),\(row.sample.shownAtMs),\(connected),\(connected - row.sample.shownAtMs),connected\n"
            } else {
                csv += "\(row.index),\(row.bundleID),\(row.sample.shownAtMs),,,timeout\n"
            }
        }
        let summary = ReconnectStats.summarize(rows.map(\.sample))
        csv += "# attempts=\(summary.attempts) successes=\(summary.successes) p95Ms=\(summary.p95Ms.map(String.init) ?? "n/a")\n"
        let attachment = XCTAttachment(string: csv)
        attachment.name = "reconnect-ui.csv"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private static func nowMs() -> Int64 { MonotonicClock.nowMs() }
}
