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
        let codes: [AckCode] = [.posted, .notAuthorized, .noFocus, .staleFocus, .switchFailed, .malformed, .compositionActive,
                                .injectFailed, .outOfOrder]
        let texts = codes.map(StatusLine.ackText)
        XCTAssertFalse(texts.contains { $0 == nil })
        XCTAssertEqual(Set(texts.compactMap { $0 }).count, codes.count)
        XCTAssertEqual(StatusLine.ackText(.posted), "Mac 已輸入")
    }

    func testNewAckCodesHaveTheirOwnWording() {
        XCTAssertEqual(StatusLine.ackText(.injectFailed), "Mac 輸入失敗")
        XCTAssertEqual(StatusLine.ackText(.outOfOrder), "順序錯誤，未輸入")
    }

    func testPongShowsNoNote() {
        XCTAssertNil(StatusLine.ackText(.pong))
    }

    func testUnconfirmedText() { XCTAssertEqual(StatusLine.unconfirmedText(2), "2 個按鍵未確認是否送達") }

    func testSuffixAddsFlashInParentheses() {
        XCTAssertEqual(StatusLine.appendingNote("Mac → TextEdit", note: "Mac 已輸入"), "Mac → TextEdit（Mac 已輸入）")
        XCTAssertEqual(StatusLine.appendingNote("Mac", note: nil), "Mac")
    }

    func testRemoteWithoutAPairKeyAsksForPairingWhateverTheLink() {
        let line = "尚未配對 Mac，請開啟主 App 配對"
        XCTAssertEqual(StatusLine.unpairedText, line)
        for link in [KeyboardLinkState.advertising, .connected, .publishing] {
            XCTAssertEqual(StatusLine.text(mode: .remote, link: link, receiver: status(), paired: false), line)
        }
    }

    func testLocalModeIgnoresPairing() {
        XCTAssertEqual(StatusLine.text(mode: .local, link: .connected, receiver: nil, paired: false), "BLE: connected")
        XCTAssertEqual(StatusLine.text(mode: .local, link: .advertising, receiver: nil, paired: false), "BLE: advertising")
    }

    func testPairedIsTheDefault() {
        XCTAssertEqual(StatusLine.text(mode: .remote, link: .connected, receiver: status()), "Mac → TextEdit")
    }

    func testConnectedLatencyIsShownInBothModes() {
        XCTAssertEqual(StatusLine.text(mode: .local, link: .connected, receiver: nil, connectedMs: 482), "BLE: connected (482 ms)")
        XCTAssertEqual(StatusLine.text(mode: .remote, link: .connected, receiver: status(), connectedMs: 482),
                       "Mac → TextEdit (482 ms)")
        XCTAssertEqual(StatusLine.text(mode: .remote, link: .connected, receiver: nil, connectedMs: 90), "Mac（等待狀態） (90 ms)")
    }

    func testLatencyIsIgnoredWhenNotConnected() {
        XCTAssertEqual(StatusLine.text(mode: .local, link: .advertising, receiver: nil, connectedMs: 482), "BLE: advertising")
    }
}
