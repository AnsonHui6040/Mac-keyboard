import XCTest
@testable import RemoteKeyboardCore

private final class FakeTextSink: TextSink {
    var inserted: [String] = []
    var deleteCount = 0
    func insertText(_ text: String) { inserted.append(text) }
    func deleteBackward() { deleteCount += 1 }
}

private final class FakeRemoteSink: RemoteEventSink {
    var events: [EventKind] = []
    func enqueue(_ kind: EventKind) { events.append(kind) }
}

final class InputRouterTests: XCTestCase {
    private func makeRouter() -> (InputRouter, FakeTextSink, FakeRemoteSink) {
        let local = FakeTextSink(), remote = FakeRemoteSink()
        return (InputRouter(local: local, remote: remote), local, remote)
    }

    func testCommitInRemoteDraftGoesToDraft() {
        var draft = DraftBuffer()
        let (router, local, remote) = makeRouter()
        // A handwriting commit is routed as a typed character.
        XCTAssertEqual(router.route(.character("香"), mode: .remote, transmit: .draft, ready: true, draft: &draft), .draftEdited)
        XCTAssertEqual(draft.text, "香")
        XCTAssertEqual(remote.events, []); XCTAssertEqual(local.inserted, [])
    }

    func testCommitInRemoteInstantSendsTextAndLocalInsertsIntoField() {
        var draft = DraftBuffer()
        let (router, local, remote) = makeRouter()
        XCTAssertEqual(router.route(.character("港"), mode: .remote, transmit: .instant, ready: true, draft: &draft), .enqueuedRemote)
        XCTAssertEqual(remote.events, [.text("港")])
        XCTAssertEqual(router.route(.character("你"), mode: .local, transmit: .instant, ready: true, draft: &draft), .insertedLocally)
        XCTAssertEqual(local.inserted, ["你"])
        XCTAssertTrue(draft.isEmpty)
    }

    func testBackspaceEditsDraftWhileDraftNotEmptyInInstant() {
        var draft = DraftBuffer(); _ = draft.insert("香港")
        let (router, _, remote) = makeRouter()
        XCTAssertEqual(router.route(.backspace, mode: .remote, transmit: .instant, ready: true, draft: &draft), .draftEdited)
        XCTAssertEqual(draft.text, "香"); XCTAssertEqual(remote.events, [])
    }

    func testNotReadyInstantWritesToDraft() {
        var draft = DraftBuffer()
        let (router, local, remote) = makeRouter()
        XCTAssertEqual(router.route(.character("a"), mode: .remote, transmit: .instant, ready: false, draft: &draft), .draftEdited)
        XCTAssertEqual(draft.text, "a")
        XCTAssertEqual(remote.events, []); XCTAssertEqual(local.inserted, [])
    }

    func testReadyInstantEmptyDraftSendsImmediately() {
        var draft = DraftBuffer()
        let (router, local, remote) = makeRouter()
        XCTAssertEqual(router.route(.character("a"), mode: .remote, transmit: .instant, ready: true, draft: &draft), .enqueuedRemote)
        XCTAssertEqual(remote.events, [.text("a")])
        XCTAssertTrue(draft.isEmpty); XCTAssertEqual(local.inserted, [])
    }

    func testReadyDraftModeWritesToDraft() {
        var draft = DraftBuffer()
        let (router, _, remote) = makeRouter()
        XCTAssertEqual(router.route(.character("a"), mode: .remote, transmit: .draft, ready: true, draft: &draft), .draftEdited)
        XCTAssertEqual(draft.text, "a"); XCTAssertEqual(remote.events, [])
    }

    func testRemoteMapsSpaceReturnAndBackspaceToSemanticEventsWhenInstant() {
        var draft = DraftBuffer()
        let (router, local, remote) = makeRouter()
        XCTAssertEqual(router.route(.space, mode: .remote, transmit: .instant, ready: true, draft: &draft), .enqueuedRemote)
        XCTAssertEqual(router.route(.returnKey, mode: .remote, transmit: .instant, ready: true, draft: &draft), .enqueuedRemote)
        XCTAssertEqual(router.route(.backspace, mode: .remote, transmit: .instant, ready: true, draft: &draft), .enqueuedRemote)
        XCTAssertEqual(remote.events, [.text(" "), .returnKey, .backspace])
        XCTAssertEqual(local.inserted, []); XCTAssertEqual(local.deleteCount, 0)
    }

    func testSpaceAndReturnInsideDraftBecomeSpaceAndLineBreak() {
        var draft = DraftBuffer()
        let (router, _, remote) = makeRouter()
        _ = router.route(.character("a"), mode: .remote, transmit: .draft, ready: true, draft: &draft)
        _ = router.route(.space, mode: .remote, transmit: .draft, ready: true, draft: &draft)
        _ = router.route(.returnKey, mode: .remote, transmit: .draft, ready: true, draft: &draft)
        XCTAssertEqual(draft.text, "a \n"); XCTAssertEqual(remote.events, [])
    }

    func testReturnWhileDraftNotEmptyInInstantEditsTheDraft() {
        var draft = DraftBuffer(); _ = draft.insert("x")
        let (router, _, remote) = makeRouter()
        XCTAssertEqual(router.route(.returnKey, mode: .remote, transmit: .instant, ready: true, draft: &draft), .draftEdited)
        XCTAssertEqual(draft.text, "x\n"); XCTAssertEqual(remote.events, [])
    }

    func testSendDraftSplitsNewlines() {
        var draft = DraftBuffer(); _ = draft.insert("ab\ncd")
        let (router, _, remote) = makeRouter()
        XCTAssertEqual(router.route(.sendDraft, mode: .remote, transmit: .draft, ready: true, draft: &draft), .draftSent(3))
        XCTAssertEqual(remote.events, [.text("ab"), .returnKey, .text("cd")]); XCTAssertTrue(draft.isEmpty)
    }

    func testSendDraftRejectedWhenNotReady() {
        var draft = DraftBuffer(); _ = draft.insert("ab")
        let (router, _, remote) = makeRouter()
        XCTAssertEqual(router.route(.sendDraft, mode: .remote, transmit: .draft, ready: false, draft: &draft), .rejected)
        XCTAssertEqual(draft.text, "ab"); XCTAssertEqual(remote.events, [])
    }

    func testSendDraftRejectedWhenDraftEmpty() {
        var draft = DraftBuffer()
        let (router, _, remote) = makeRouter()
        XCTAssertEqual(router.route(.sendDraft, mode: .remote, transmit: .draft, ready: true, draft: &draft), .rejected)
        XCTAssertEqual(remote.events, [])
    }

    func testSendDraftCountsEveryEventIncludingChunks() {
        var draft = DraftBuffer()
        _ = draft.insert(String(repeating: "👨‍👩‍👧‍👦", count: 100))
        let (router, _, remote) = makeRouter()
        let outcome = router.route(.sendDraft, mode: .remote, transmit: .draft, ready: true, draft: &draft)
        XCTAssertEqual(outcome, .draftSent(remote.events.count))
        XCTAssertGreaterThan(remote.events.count, 1)
    }

    func testArrowKeysNeverReachMac() {
        for transmit in [TransmitMode.instant, .draft] {
            var draft = DraftBuffer(); _ = draft.insert("ab")
            let (router, local, remote) = makeRouter()
            XCTAssertEqual(router.route(.cursorLeft, mode: .remote, transmit: transmit, ready: true, draft: &draft), .draftEdited)
            XCTAssertEqual(draft.cursor, 1)
            XCTAssertEqual(router.route(.cursorRight, mode: .remote, transmit: transmit, ready: true, draft: &draft), .draftEdited)
            XCTAssertEqual(draft.cursor, 2)
            XCTAssertEqual(remote.events, []); XCTAssertEqual(local.inserted, []); XCTAssertEqual(local.deleteCount, 0)
        }
    }

    func testDraftCapReportsDraftFullAndLeavesDraftUnchanged() {
        var draft = DraftBuffer(); _ = draft.insert(String(repeating: "a", count: DraftBuffer.maxCharacters))
        let (router, _, remote) = makeRouter()
        XCTAssertEqual(router.route(.character("b"), mode: .remote, transmit: .draft, ready: true, draft: &draft), .draftFull)
        XCTAssertEqual(router.route(.space, mode: .remote, transmit: .draft, ready: true, draft: &draft), .draftFull)
        XCTAssertEqual(router.route(.returnKey, mode: .remote, transmit: .draft, ready: true, draft: &draft), .draftFull)
        XCTAssertEqual(draft.text.count, 1_000); XCTAssertEqual(remote.events, [])
    }

    func testLocalModeIgnoresDraft() {
        var draft = DraftBuffer(); _ = draft.insert("x")
        let (router, local, remote) = makeRouter()
        XCTAssertEqual(router.route(.character("a"), mode: .local, transmit: .draft, ready: true, draft: &draft), .insertedLocally)
        XCTAssertEqual(local.inserted, ["a"]); XCTAssertEqual(draft.text, "x"); XCTAssertEqual(remote.events, [])
    }

    func testLocalModeSpaceReturnAndBackspaceGoToTheField() {
        var draft = DraftBuffer(); _ = draft.insert("x")
        let (router, local, remote) = makeRouter()
        _ = router.route(.space, mode: .local, transmit: .instant, ready: false, draft: &draft)
        _ = router.route(.returnKey, mode: .local, transmit: .instant, ready: false, draft: &draft)
        _ = router.route(.backspace, mode: .local, transmit: .instant, ready: false, draft: &draft)
        XCTAssertEqual(local.inserted, [" ", "\n"]); XCTAssertEqual(local.deleteCount, 1)
        XCTAssertEqual(draft.text, "x"); XCTAssertEqual(remote.events, [])
    }

    func testLocalModeCursorAndSendDraftChangeNothing() {
        var draft = DraftBuffer(); _ = draft.insert("xy")
        let (router, local, remote) = makeRouter()
        for action in [KeyAction.cursorLeft, .cursorRight, .sendDraft] {
            XCTAssertEqual(router.route(action, mode: .local, transmit: .draft, ready: true, draft: &draft), .rejected)
        }
        XCTAssertEqual(draft.text, "xy"); XCTAssertEqual(draft.cursor, 2)
        XCTAssertEqual(local.inserted, []); XCTAssertEqual(remote.events, [])
    }

    func testToggleModeReturnsOppositeModeAndTouchesNoSink() {
        var draft = DraftBuffer(); _ = draft.insert("x")
        let (router, local, remote) = makeRouter()
        XCTAssertEqual(router.route(.toggleMode, mode: .local, transmit: .instant, ready: true, draft: &draft), .modeToggled(.remote))
        XCTAssertEqual(router.route(.toggleMode, mode: .remote, transmit: .instant, ready: true, draft: &draft), .modeToggled(.local))
        XCTAssertEqual(draft.text, "x"); XCTAssertEqual(local.inserted, []); XCTAssertEqual(remote.events, [])
    }

    func testToggleTransmitReturnsOppositeAndKeepsTheDraft() {
        var draft = DraftBuffer(); _ = draft.insert("x")
        let (router, _, remote) = makeRouter()
        XCTAssertEqual(router.route(.toggleTransmit, mode: .remote, transmit: .instant, ready: true, draft: &draft), .transmitToggled(.draft))
        XCTAssertEqual(router.route(.toggleTransmit, mode: .remote, transmit: .draft, ready: true, draft: &draft), .transmitToggled(.instant))
        XCTAssertEqual(draft.text, "x"); XCTAssertEqual(remote.events, [])
    }

    func testPageKeysReportPageChangedAndTouchNothing() {
        var draft = DraftBuffer()
        let (router, local, remote) = makeRouter()
        for mode in [KeyboardMode.local, .remote] {
            XCTAssertEqual(router.route(.switchChineseEnglish, mode: mode, transmit: .instant, ready: true, draft: &draft), .pageChanged)
            XCTAssertEqual(router.route(.switchSymbols, mode: mode, transmit: .instant, ready: true, draft: &draft), .pageChanged)
        }
        XCTAssertEqual(local.inserted, []); XCTAssertEqual(remote.events, []); XCTAssertTrue(draft.isEmpty)
    }

    func testNextKeyboardIsAvailableInBothModes() {
        var draft = DraftBuffer()
        let (router, _, remote) = makeRouter()
        XCTAssertEqual(router.route(.nextKeyboard, mode: .local, transmit: .instant, ready: false, draft: &draft), .advanceInputMode)
        XCTAssertEqual(router.route(.nextKeyboard, mode: .remote, transmit: .instant, ready: true, draft: &draft), .advanceInputMode)
        XCTAssertEqual(remote.events, [])
    }

    func testDismissKeyboardOnlyReportsDismissAndKeepsTheDraft() {
        var draft = DraftBuffer()
        _ = draft.insert("keep")
        let (router, local, remote) = makeRouter()
        for mode in [KeyboardMode.local, .remote] {
            for transmit in [TransmitMode.instant, .draft] {
                XCTAssertEqual(router.route(.dismissKeyboard, mode: mode, transmit: transmit, ready: true, draft: &draft), .dismissKeyboard)
            }
        }
        XCTAssertEqual(draft.text, "keep"); XCTAssertEqual(local.inserted, []); XCTAssertEqual(remote.events, [])
    }

    func testReadinessIsDecidedPerKey() {
        var draft = DraftBuffer()
        let (router, _, remote) = makeRouter()
        XCTAssertEqual(router.route(.character("a"), mode: .remote, transmit: .instant, ready: false, draft: &draft), .draftEdited)
        // The draft now holds "a", so the next key keeps editing it even though the Mac became ready.
        XCTAssertEqual(router.route(.character("b"), mode: .remote, transmit: .instant, ready: true, draft: &draft), .draftEdited)
        XCTAssertEqual(draft.text, "ab"); XCTAssertEqual(remote.events, [])
    }
}
