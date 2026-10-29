import RemoteKeyboardCore
import XCTest

/// T06 reconnect gate, driven from outside the keyboard process.
///
/// Run on a physical iPhone only, with the Mac Receiver already armed (press 開始接收 on the Mac first) and
/// "Remote Keyboard" already selected as the current keyboard. The Mac's `reconnect.csv` is the authoritative
/// record; this test's own numbers include XCUITest query latency and are only a cross-check.
@MainActor
final class ReconnectUITests: XCTestCase {
    private static let apps = ["com.apple.mobilenotes", "com.apple.mobilesafari"]
    private static let statusIdentifier = "rk.status"
    private static let connectTimeoutSeconds = 10.0
    private static let defaultCount = 100

    private struct Row {
        let index: Int
        let bundleID: String
        let sample: ReconnectSample
    }

    override func setUp() {
        continueAfterFailure = false
    }

    func testHundredReopens() throws {
        // TEST_RUNNER_RK_REOPEN_COUNT=3 gives a short dry run; the gate itself is the default 100.
        let count = ProcessInfo.processInfo.environment["RK_REOPEN_COUNT"].flatMap(Int.init) ?? Self.defaultCount
        var rows: [Row] = []

        for index in 0..<count {
            let bundleID = Self.apps[index % Self.apps.count]
            let app = XCUIApplication(bundleIdentifier: bundleID)
            app.activate()
            guard focusTextInput(in: app) else {
                XCTFail("no text input found in \(bundleID) at reopen \(index + 1)")
                break
            }
            let shownAt = Self.nowMs()
            let status = app.descendants(matching: .any).matching(identifier: Self.statusIdentifier).firstMatch

            if index == 0 {
                // O6: the third-party keyboard must be reachable at all. Try the globe a few times first.
                var found = status.waitForExistence(timeout: Self.connectTimeoutSeconds)
                var tries = 0
                while !found && tries < 6 {
                    tries += 1
                    let next = app.keyboards.buttons["Next keyboard"]
                    guard next.exists else { break }
                    next.tap()
                    found = status.waitForExistence(timeout: 2)
                }
                guard found else { throw XCTSkip("O6: third-party keyboard not reachable") }
            }

            let connectedAt = waitForConnected(status, shownAt: shownAt)
            rows.append(Row(index: index + 1, bundleID: bundleID, sample: ReconnectSample(shownAtMs: shownAt, connectedAtMs: connectedAt)))
            hideKeyboard(in: app)
        }

        attach(rows)
        let summary = ReconnectStats.summarize(rows.map(\.sample))
        XCTAssertEqual(summary.attempts, count)
        // At least 99 of 100 connected (scaled for dry runs) and P95 at most 2000 ms.
        XCTAssertGreaterThanOrEqual(summary.successes * 100, summary.attempts * 99, "connected \(summary.successes)/\(summary.attempts)")
        XCTAssertLessThanOrEqual(summary.p95Ms ?? .max, 2000, "P95 \(summary.p95Ms.map(String.init) ?? "n/a") ms")
    }

    // MARK: Steps

    private func focusTextInput(in app: XCUIApplication) -> Bool {
        func tapFirst(_ query: XCUIElementQuery) -> Bool {
            let element = query.firstMatch
            guard element.waitForExistence(timeout: 3) else { return false }
            element.tap()
            return true
        }
        if tapFirst(app.textViews) || tapFirst(app.textFields) || tapFirst(app.searchFields) { return true }
        // Notes opens on its folder or note list; start a new note to get a text view.
        for name in ["New Note", "Compose", "Create"] {
            let button = app.buttons[name]
            if button.waitForExistence(timeout: 2) {
                button.tap()
                if tapFirst(app.textViews) { return true }
            }
        }
        // Safari: the address bar is a button until it is tapped.
        let address = app.buttons["Address"]
        if address.waitForExistence(timeout: 2) {
            address.tap()
            return tapFirst(app.textFields)
        }
        return false
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
