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
        let line = "尚未配對"
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

    // MARK: Several hosts (WL4): the host name as a title, wording by platform

    private func host(_ name: String = "書房的 Mac", _ platform: HostPlatform = .mac) -> HostIdentity {
        HostIdentity(id: Data(repeating: 7, count: 16), name: name, platform: platform)
    }

    private func display(
        host: HostIdentity?, hostCount: Int, _ link: KeyboardLinkState = .connected, mode: KeyboardMode = .remote,
        receiver: ReceiverStatus? = nil, paired: Bool = true, note: String? = nil
    ) -> StatusLine.Display? {
        StatusLine.display(
            mode: mode, link: link, receiver: receiver, paired: paired, note: note, host: host, hostCount: hostCount)
    }

    func testSingleHostShowsItsNameButDoesNotSwitch() {
        let shown = display(host: host("Mac"), hostCount: 1, receiver: status())
        XCTAssertEqual(shown, StatusLine.Display(text: "已連接", tone: .connected, title: "Mac", switchesHost: false))
        XCTAssertEqual(
            display(host: host("Mac"), hostCount: 1, .advertising),
            StatusLine.Display(text: "未連接", tone: .problem, title: "Mac", switchesHost: false))
    }

    func testSwitchesHostOnlyWithTwoOrMoreHosts() {
        XCTAssertEqual(display(host: host(), hostCount: 1, receiver: status())?.switchesHost, false)
        XCTAssertEqual(display(host: host(), hostCount: 2, receiver: status())?.switchesHost, true)
        XCTAssertEqual(display(host: host(), hostCount: 5, .advertising)?.switchesHost, true)
        XCTAssertEqual(display(host: host(), hostCount: 1, receiver: status(), note: "Mac 輸入失敗")?.switchesHost, false)
        XCTAssertEqual(display(host: host(), hostCount: 2, receiver: status(), note: "Mac 輸入失敗")?.switchesHost, true)
    }

    func testUnpairedHasNoTitleAndNoSwitch() {
        for count in [0, 1, 2] {
            XCTAssertEqual(
                display(host: nil, hostCount: count, .advertising, paired: false),
                StatusLine.Display(text: "尚未配對", tone: .problem))
        }
        XCTAssertNil(display(host: host(), hostCount: 2, receiver: status(), paired: false)?.title)
    }

    func testTwoHostsShowHostNameAsTitle() {
        let shown = display(host: host("書房的 Mac"), hostCount: 2, receiver: status())
        XCTAssertEqual(shown?.title, "書房的 Mac")
        XCTAssertEqual(shown?.text, "已連接")
        XCTAssertEqual(display(host: host("書房的 Mac"), hostCount: 2, .advertising)?.title, "書房的 Mac")
        XCTAssertEqual(display(host: host("客廳"), hostCount: 8, receiver: status(), note: "Mac 輸入失敗")?.title, "客廳")
    }

    func testTitleNeedsAHostAndRemoteMode() {
        XCTAssertNil(display(host: nil, hostCount: 2, receiver: status())?.title)
        XCTAssertEqual(display(host: host("客廳"), hostCount: 0, receiver: status())?.title, "客廳")
        XCTAssertEqual(display(host: host("客廳"), hostCount: 0, receiver: status())?.switchesHost, false)
        XCTAssertNil(display(host: host(), hostCount: 2, mode: .local))
        XCTAssertNil(display(host: host(), hostCount: 2, mode: .local, note: "2 個按鍵未確認是否送達")?.title)
    }

    func testLinuxUntrustedSaysComputerNotAuthorized() {
        let untrusted = ReceiverStatus(ready: false, appName: nil, focusEpoch: 1, trusted: false)
        XCTAssertEqual(display(host: host("Ubuntu", .linux), hostCount: 1, receiver: untrusted),
                       StatusLine.Display(text: "電腦未授權", tone: .problem, title: "Ubuntu"))
        XCTAssertEqual(display(host: host("Ubuntu", .linux), hostCount: 2, .advertising, receiver: untrusted)?.text, "未連接")
    }

    func testMacUntrustedKeepsExistingText() {
        let untrusted = ReceiverStatus(ready: false, appName: "Finder", focusEpoch: 2, trusted: false)
        XCTAssertEqual(display(host: host(), hostCount: 1, receiver: untrusted),
                       StatusLine.Display(text: "Mac 未授權輔助使用", tone: .problem, title: "書房的 Mac"))
        XCTAssertEqual(display(host: nil, hostCount: 1, receiver: untrusted)?.text, "Mac 未授權輔助使用")
    }

    func testWindowsNeverShowsInputBlocked() {
        let blockedStatus = ReceiverStatus(ready: false, appName: nil, focusEpoch: 1, inputBlocked: true)
        for platform in [HostPlatform.windows, .linux] {
            XCTAssertEqual(display(host: host("PC", platform), hostCount: 1, receiver: blockedStatus),
                           StatusLine.Display(text: "已連接", tone: .connected, title: "PC"))
        }
        XCTAssertEqual(display(host: host(), hostCount: 1, receiver: blockedStatus)?.text, "密碼不能輸入")
    }

    func testOtherPlatformsSayComputerInsteadOfMac() {
        let ready = ReceiverStatus(ready: true, appName: nil, focusEpoch: 1)
        let notReady = ReceiverStatus(ready: false, appName: nil, focusEpoch: 1)
        XCTAssertEqual(StatusLine.text(mode: .remote, link: .connected, receiver: ready, platform: .windows), "電腦")
        XCTAssertEqual(StatusLine.text(mode: .remote, link: .connected, receiver: nil, platform: .linux), "電腦（等待狀態）")
        XCTAssertEqual(StatusLine.text(mode: .remote, link: .connected, receiver: notReady, platform: .windows), "電腦（無法輸入）")
        XCTAssertEqual(StatusLine.text(mode: .remote, link: .connected, receiver: ready, platform: .mac), "Mac")
        XCTAssertEqual(StatusLine.droppedKeyNote(link: .advertising, receiver: nil, platform: .linux), "電腦未連接，未輸入")
        XCTAssertEqual(StatusLine.droppedKeyNote(link: .connected, receiver: notReady, platform: .windows), "電腦尚未就緒，未輸入")
        XCTAssertEqual(StatusLine.droppedKeyNote(link: .connected, receiver: notReady, platform: .mac), "Mac 沒有輸入欄位，未輸入")
        XCTAssertEqual(StatusLine.ackText(.notAuthorized, platform: .linux), "電腦未授權")
        XCTAssertEqual(StatusLine.ackText(.injectFailed, platform: .windows), "電腦輸入失敗")
        XCTAssertEqual(StatusLine.ackText(.injectFailed, platform: .mac), "Mac 輸入失敗")
        XCTAssertNil(StatusLine.ackText(.pong, platform: .windows))
    }

    func testPostedNoteOfAnyPlatformCountsAsNoNote() {
        let posted = StatusLine.ackText(.posted, platform: .windows)
        XCTAssertEqual(display(host: host("PC", .windows), hostCount: 1, receiver: status(), note: posted)?.text, "已連接")
        XCTAssertEqual(display(host: host("PC", .windows), hostCount: 1, receiver: status(), note: StatusLine.ackText(.posted))?.text, "已連接")
    }
}
