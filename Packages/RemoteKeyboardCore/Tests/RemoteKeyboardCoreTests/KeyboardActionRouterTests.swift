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

final class KeyboardActionRouterTests: XCTestCase {
    private func makeRouter(ready: Bool = false) -> (KeyboardActionRouter, FakeTextSink, FakeRemoteSink) {
        let local = FakeTextSink()
        let remote = FakeRemoteSink()
        return (KeyboardActionRouter(local: local, remote: remote, isRemoteReady: { ready }), local, remote)
    }

    func testLocalModeInsertsAWithoutFullAccess() {
        let (router, local, remote) = makeRouter()
        XCTAssertEqual(router.route(.character("A"), mode: .local), .insertedLocally)
        XCTAssertEqual(local.inserted, ["A"])
        XCTAssertEqual(remote.events, [])
    }

    func testGlobeSwitchIsAvailable() {
        let (router, local, _) = makeRouter()
        XCTAssertEqual(router.route(.nextKeyboard, mode: .local), .advanceInputMode)
        XCTAssertEqual(local.inserted, [])
    }

    func testSpaceAndReturnInsertLocally() {
        let (router, local, _) = makeRouter()
        _ = router.route(.space, mode: .local)
        _ = router.route(.returnKey, mode: .local)
        XCTAssertEqual(local.inserted, [" ", "\n"])
    }

    func testBackspaceDeletesLocally() {
        let (router, local, _) = makeRouter()
        _ = router.route(.backspace, mode: .local)
        XCTAssertEqual(local.deleteCount, 1)
    }

    func testToggleModeReturnsOppositeModeAndTouchesNoSink() {
        let (router, local, remote) = makeRouter()
        XCTAssertEqual(router.route(.toggleMode, mode: .local), .modeToggled(.remote))
        XCTAssertEqual(router.route(.toggleMode, mode: .remote), .modeToggled(.local))
        XCTAssertEqual(local.inserted, [])
        XCTAssertEqual(local.deleteCount, 0)
        XCTAssertEqual(remote.events, [])
    }

    func testRemoteModeRejectsTypingAndTouchesNoSink() {
        let (router, local, remote) = makeRouter()
        XCTAssertEqual(router.route(.character("A"), mode: .remote), .rejected)
        XCTAssertEqual(router.route(.backspace, mode: .remote), .rejected)
        XCTAssertEqual(local.inserted, [])
        XCTAssertEqual(local.deleteCount, 0)
        XCTAssertEqual(remote.events, [])
    }

    func testTapAProducesOneRemoteSemanticEvent() {
        let (router, local, remote) = makeRouter(ready: true)
        XCTAssertEqual(router.route(.character("A"), mode: .remote), .enqueuedRemote)
        XCTAssertEqual(remote.events, [.text("A")]); XCTAssertEqual(local.inserted, [])
    }

    func testRemoteNotReadyRejectsWithoutLocalFallback() {
        let (router, local, remote) = makeRouter(ready: false)
        XCTAssertEqual(router.route(.character("A"), mode: .remote), .rejected)
        XCTAssertEqual(remote.events, []); XCTAssertEqual(local.inserted, [])
    }

    func testRemoteMapsSpaceReturnAndBackspaceToSemanticEvents() {
        let (router, local, remote) = makeRouter(ready: true)
        XCTAssertEqual(router.route(.space, mode: .remote), .enqueuedRemote)
        XCTAssertEqual(router.route(.returnKey, mode: .remote), .enqueuedRemote)
        XCTAssertEqual(router.route(.backspace, mode: .remote), .enqueuedRemote)
        XCTAssertEqual(remote.events, [.text(" "), .returnKey, .backspace])
        XCTAssertEqual(local.inserted, []); XCTAssertEqual(local.deleteCount, 0)
    }

    func testRemoteReadyDoesNotAffectLocalMode() {
        let (router, local, remote) = makeRouter(ready: true)
        XCTAssertEqual(router.route(.character("A"), mode: .local), .insertedLocally)
        XCTAssertEqual(local.inserted, ["A"]); XCTAssertEqual(remote.events, [])
    }

    func testReadinessIsEvaluatedPerKey() {
        var ready = false
        let local = FakeTextSink(), remote = FakeRemoteSink()
        let router = KeyboardActionRouter(local: local, remote: remote, isRemoteReady: { ready })
        XCTAssertEqual(router.route(.character("a"), mode: .remote), .rejected)
        ready = true
        XCTAssertEqual(router.route(.character("b"), mode: .remote), .enqueuedRemote)
        XCTAssertEqual(remote.events, [.text("b")])
    }

    func testNextKeyboardIsAvailableInRemoteMode() {
        let (router, _, remote) = makeRouter(ready: true)
        XCTAssertEqual(router.route(.nextKeyboard, mode: .remote), .advanceInputMode)
        XCTAssertEqual(remote.events, [])
    }
}
