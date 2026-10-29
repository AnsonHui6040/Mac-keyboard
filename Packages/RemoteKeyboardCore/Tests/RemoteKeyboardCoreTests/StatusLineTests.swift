import XCTest
@testable import RemoteKeyboardCore

final class StatusLineTests: XCTestCase {
    private func status(ready: Bool = true, app: String? = "TextEdit") -> ReceiverStatus {
        ReceiverStatus(ready: ready, appName: app, focusEpoch: 4)
    }

    func testLocalModeShowsTheLinkLineUnchanged() {
        XCTAssertEqual(StatusLine.text(mode: .local, link: .advertising, receiver: nil), "BLE: advertising")
        XCTAssertEqual(StatusLine.text(mode: .local, link: .connected, receiver: status()), "BLE: connected")
    }

    func testRemoteConnectedReadyShowsMacArrowAppName() {
        XCTAssertEqual(StatusLine.text(mode: .remote, link: .connected, receiver: status()), "Mac → TextEdit")
    }

    func testRemoteConnectedWithoutAppNameFallsBackToMac() {
        XCTAssertEqual(StatusLine.text(mode: .remote, link: .connected, receiver: status(app: nil)), "Mac")
    }

    func testRemoteNotReadyAndNoStatusAreDistinguished() {
        XCTAssertEqual(StatusLine.text(mode: .remote, link: .connected, receiver: status(ready: false, app: "Finder")),
                       "Mac → Finder（無輸入欄位）")
        XCTAssertEqual(StatusLine.text(mode: .remote, link: .connected, receiver: nil), "Mac（等待狀態）")
    }

    func testRemoteNotConnectedShowsLinkLine() {
        XCTAssertEqual(StatusLine.text(mode: .remote, link: .advertising, receiver: status()), "BLE: advertising")
    }

    func testAckTextCoversEveryCodeDistinctly() {
        let codes: [AckCode] = [.posted, .notAuthorized, .noFocus, .staleFocus, .switchFailed, .malformed, .compositionActive]
        XCTAssertEqual(Set(codes.map(StatusLine.ackText)).count, codes.count)
        XCTAssertEqual(StatusLine.ackText(.posted), "Mac 已輸入")
    }

    func testSuffixAddsFlashInParentheses() {
        XCTAssertEqual(StatusLine.appendingNote("Mac → TextEdit", note: "Mac 已輸入"), "Mac → TextEdit（Mac 已輸入）")
        XCTAssertEqual(StatusLine.appendingNote("Mac", note: nil), "Mac")
    }
}
