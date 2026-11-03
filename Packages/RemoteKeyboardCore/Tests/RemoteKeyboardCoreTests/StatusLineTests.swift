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

    func testReceiverNotAuthorizedShowsAuthorizationText() {
        let untrusted = ReceiverStatus(ready: false, appName: "Finder", focusEpoch: 2, trusted: false)
        XCTAssertEqual(StatusLine.text(mode: .remote, link: .connected, receiver: untrusted), "Mac 未授權輔助使用")
        XCTAssertEqual(StatusLine.text(mode: .remote, link: .connected, receiver: untrusted, connectedMs: 90),
                       "Mac 未授權輔助使用 (90 ms)")
        XCTAssertEqual(StatusLine.text(mode: .local, link: .connected, receiver: untrusted), "BLE: connected")
    }

    func testTrustedButNoFieldStillSaysNoInputField() {
        XCTAssertEqual(StatusLine.text(mode: .remote, link: .connected, receiver: status(ready: false, app: "Finder")),
                       "Mac → Finder（無輸入欄位）")
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

    func testNoteAlreadyInTheLineIsNotRepeated() {
        XCTAssertEqual(StatusLine.appendingNote("Mac 未授權輔助使用", note: "Mac 未授權輔助使用"), "Mac 未授權輔助使用")
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

    // MARK: Display (text and tone)

    private func display(
        _ link: KeyboardLinkState = .connected, mode: KeyboardMode = .remote, receiver: ReceiverStatus? = nil,
        paired: Bool = true, note: String? = nil
    ) -> StatusLine.Display? {
        StatusLine.display(mode: mode, link: link, receiver: receiver, paired: paired, note: note)
    }

    func testDisplayUnpairedRemoteComesFirstAndIsAProblem() {
        let expected = StatusLine.Display(text: "尚未配對", tone: .problem)
        for link in [KeyboardLinkState.advertising, .connected, .publishing] {
            XCTAssertEqual(display(link, receiver: status(), paired: false, note: "Mac 輸入失敗"), expected)
        }
    }

    func testDisplayNoteWinsOverLinkState() {
        XCTAssertEqual(display(receiver: status(), note: "Mac 輸入失敗"), .init(text: "Mac 輸入失敗", tone: .problem))
        XCTAssertEqual(display(.advertising, note: "焦點已改變，未輸入"), .init(text: "焦點已改變，未輸入", tone: .problem))
    }

    func testDisplayPostedNoteCountsAsNoNote() {
        let posted = StatusLine.ackText(.posted)
        XCTAssertEqual(display(receiver: status(), note: posted), .init(text: "已連接", tone: .connected))
        XCTAssertEqual(display(.advertising, note: posted), .init(text: "未連接", tone: .problem))
    }

    func testDisplayUntrustedReceiverNeedsAConnectedLink() {
        let untrusted = ReceiverStatus(ready: false, appName: "Finder", focusEpoch: 2, trusted: false)
        XCTAssertEqual(display(receiver: untrusted), .init(text: "Mac 未授權輔助使用", tone: .problem))
        XCTAssertEqual(display(.advertising, receiver: untrusted), .init(text: "未連接", tone: .problem))
    }

    func testDisplayConnectedIsGreenWithoutAppNameOrLatency() {
        XCTAssertEqual(display(receiver: status(app: "TextEdit")), .init(text: "已連接", tone: .connected))
        XCTAssertEqual(display(receiver: nil), .init(text: "已連接", tone: .connected))
        XCTAssertEqual(display(receiver: status(ready: false, app: "Finder")), .init(text: "已連接", tone: .connected))
    }

    func testDisplayAnyOtherLinkIsNotConnected() {
        for link in [KeyboardLinkState.idle, .advertising, .publishing] {
            XCTAssertEqual(display(link, receiver: status()), .init(text: "未連接", tone: .problem))
        }
    }

    func testDisplayLocalModeShowsNothingWithoutANote() {
        for link in [KeyboardLinkState.advertising, .connected] {
            XCTAssertNil(display(link, mode: .local))
            XCTAssertNil(display(link, mode: .local, paired: false))
            XCTAssertNil(display(link, mode: .local, note: StatusLine.ackText(.posted)))
        }
    }

    func testDisplayLocalModeShowsANoteAsAProblem() {
        XCTAssertEqual(display(.connected, mode: .local, note: "2 個按鍵未確認是否送達"),
                       .init(text: "2 個按鍵未確認是否送達", tone: .problem))
    }

    func testDisplayDoesNotChangeTheOldText() {
        XCTAssertEqual(StatusLine.text(mode: .remote, link: .connected, receiver: status(), connectedMs: 90), "Mac → TextEdit (90 ms)")
    }

    // MARK: Input blocked (password field, secure input, locked screen)

    private func blocked(app: String? = "Safari") -> ReceiverStatus {
        ReceiverStatus(ready: false, appName: app, focusEpoch: 6, inputBlocked: true)
    }

    func testDisplayBlockedConnectedSaysThePasswordCannotBeTyped() {
        XCTAssertEqual(display(receiver: blocked()), .init(text: "密碼不能輸入", tone: .problem))
        XCTAssertEqual(display(receiver: blocked(app: nil)), .init(text: "密碼不能輸入", tone: .problem))
    }

    func testDisplayBlockedOrderIsUnpairedThenNoteThenUntrustedThenBlocked() {
        let problem = { (text: String) in StatusLine.Display(text: text, tone: .problem) }
        XCTAssertEqual(display(receiver: blocked(), paired: false, note: "x"), problem("尚未配對"))
        XCTAssertEqual(display(receiver: blocked(), note: "Mac 輸入失敗"), problem("Mac 輸入失敗"))
        let untrustedAndBlocked = ReceiverStatus(ready: false, appName: "Safari", focusEpoch: 6, trusted: false, inputBlocked: true)
        XCTAssertEqual(display(receiver: untrustedAndBlocked), problem("Mac 未授權輔助使用"))
        XCTAssertEqual(display(receiver: blocked(), note: StatusLine.ackText(.posted)), problem("密碼不能輸入"))
    }

    func testDisplayBlockedNeedsAConnectedRemoteLink() {
        XCTAssertEqual(display(.advertising, receiver: blocked()), .init(text: "未連接", tone: .problem))
        XCTAssertNil(display(.connected, mode: .local, receiver: blocked()))
    }

    func testDisplayBlockedClearsWhenTheStateEnds() {
        XCTAssertEqual(display(receiver: status(ready: false, app: "Safari")), .init(text: "已連接", tone: .connected))
    }

    func testDroppedKeyNoteSaysWhyOnlyWhenTheStatusLineDoesNot() {
        XCTAssertEqual(StatusLine.droppedKeyNote(link: .advertising, receiver: nil), "Mac 未連接，未輸入")
        XCTAssertEqual(StatusLine.droppedKeyNote(link: .idle, receiver: status()), "Mac 未連接，未輸入")
        XCTAssertEqual(StatusLine.droppedKeyNote(link: .connected, receiver: status(ready: false, app: "Finder")), "Mac 沒有輸入欄位，未輸入")
        XCTAssertEqual(StatusLine.droppedKeyNote(link: .connected, receiver: nil), "Mac 尚未就緒，未輸入")
        XCTAssertNil(StatusLine.droppedKeyNote(link: .connected, receiver: blocked()))
        let untrusted = ReceiverStatus(ready: false, appName: "Finder", focusEpoch: 2, trusted: false)
        XCTAssertNil(StatusLine.droppedKeyNote(link: .connected, receiver: untrusted))
    }

    func testTextNamesThePasswordFieldWhileBlocked() {
        XCTAssertEqual(StatusLine.text(mode: .remote, link: .connected, receiver: blocked()), "Mac → Safari（密碼欄，不能輸入）")
        XCTAssertEqual(
            StatusLine.text(mode: .remote, link: .connected, receiver: blocked(app: nil), connectedMs: 80), "Mac（密碼欄，不能輸入） (80 ms)")
        XCTAssertEqual(
            StatusLine.text(mode: .remote, link: .connected, receiver: status(ready: false, app: "Finder")), "Mac → Finder（無輸入欄位）")
    }
}
