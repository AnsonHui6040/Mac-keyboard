import XCTest

/// Pairing and host selection driven from outside the app, for the receiver end-to-end runs.
///
/// Both tests need the Bluetooth permission already granted and run on a physical iPhone only. Neither writes the pairing
/// code anywhere except the attachment and the `RKPAIR` line, which the receiver-side script compares with its own dialog.
///
/// `testPairNewComputer` environment (`TEST_RUNNER_` prefix on the xcodebuild side):
/// - `RK_EXPECT_HOST`: when set, the host name the phone shows must equal it.
///
/// `testSelectComputer` environment:
/// - `RK_SELECT_HOST`: required; the row of 已配對電腦 whose label contains it becomes the current host.
@MainActor
final class PairingUITests: XCTestCase {
    private static let sasTimeout: TimeInterval = 120
    private static let finishTimeout: TimeInterval = 60

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testPairNewComputer() throws {
        let app = XCUIApplication()
        openHostList(app)

        let pair = element(app, "rk.home.pairMac")
        XCTAssertTrue(pair.waitForExistence(timeout: 10), "新增電腦 (rk.home.pairMac) not found")
        pair.tap()

        let sasLabel = element(app, "rk.pairing.sas")
        guard sasLabel.waitForExistence(timeout: Self.sasTimeout) else {
            XCTFail("no pairing code within \(Int(Self.sasTimeout)) s; was 配對新手機 pressed on the receiver?")
            return
        }
        let sas = sasLabel.label
        let host = element(app, "rk.pairing.hostName").label
        let digits = sas.filter(\.isNumber)
        print("RKPAIR sas=\(digits) host=\(host)")

        let attachment = XCTAttachment(string: "sas=\(digits)\nhost=\(host)\n")
        attachment.name = "pairing.txt"
        attachment.lifetime = .keepAlways
        add(attachment)

        if let expected = ProcessInfo.processInfo.environment["RK_EXPECT_HOST"], !expected.isEmpty {
            XCTAssertEqual(host, expected, "paired host name differs from RK_EXPECT_HOST")
            if host != expected { return }
        }

        let confirm = app.buttons["確認"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "確認 button not found")
        confirm.tap()

        let done = app.buttons["完成"]
        XCTAssertTrue(
            done.waitForExistence(timeout: Self.finishTimeout),
            "完成 not shown within \(Int(Self.finishTimeout)) s; did the receiver dialog get a yes?")
        done.tap()
        print("RKPAIR done host=\(host)")
    }

    func testSelectComputer() throws {
        guard let wanted = ProcessInfo.processInfo.environment["RK_SELECT_HOST"], !wanted.isEmpty else {
            XCTFail("RK_SELECT_HOST is not set (pass TEST_RUNNER_RK_SELECT_HOST)")
            return
        }
        let app = XCUIApplication()
        openHostList(app)

        let rows = app.descendants(matching: .any).matching(identifier: "rk.home.host")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "no paired computer rows")
        let row = rows.matching(NSPredicate(format: "label CONTAINS %@", wanted)).firstMatch
        guard row.exists else {
            let names = rows.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
            XCTFail("no row contains [\(wanted)]; rows: \(names)")
            return
        }
        row.tap()
        // The row's accessibility value reads 目前使用 once it is current.
        let current = rows.matching(NSPredicate(format: "label CONTAINS %@ AND value == %@", wanted, "目前使用")).firstMatch
        XCTAssertTrue(current.waitForExistence(timeout: 5), "[\(wanted)] is not marked 目前使用 after the tap")
        print("RKSELECT host=\(wanted)")
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Launches without the first launch guide and opens 已配對電腦.
    private func openHostList(_ app: XCUIApplication) {
        app.launchArguments += ["-rkSkipOnboarding"]
        app.launch()
        // Inside the 設定完成／連線有問題 group the row keeps its label but not always its identifier, and the group may be
        // collapsed: look by identifier or label, and open the group only when the row is not there.
        let byLabel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "已配對電腦")).firstMatch
        var link = element(app, "rk.home.pairing")
        if !link.waitForExistence(timeout: 3) {
            if !byLabel.exists {
                for group in ["rk.home.setupDone", "rk.home.setupProblem"] {
                    let row = element(app, group)
                    if row.exists { row.tap(); break }
                }
            }
            link = element(app, "rk.home.pairing").exists ? element(app, "rk.home.pairing") : byLabel
        }
        XCTAssertTrue(link.waitForExistence(timeout: 10), "已配對電腦 (rk.home.pairing) not found")
        link.tap()
    }
}
