import XCTest
@testable import RemoteKeyboardCore

private final class FakeTextSink: TextSink {
    var inserted: [String] = []
    var deleteCount = 0
    func insertText(_ text: String) { inserted.append(text) }
    func deleteBackward() { deleteCount += 1 }
}

/// `KeyboardActionRouter` is the Local half of routing: it only writes into the host app's field. Everything that
/// depends on mode, draft or readiness is `InputRouter` (see `InputRouterTests`).
final class KeyboardActionRouterTests: XCTestCase {
    private func makeRouter() -> (KeyboardActionRouter, FakeTextSink) {
        let local = FakeTextSink()
        return (KeyboardActionRouter(local: local), local)
    }

    func testTextIsInsertedWithoutFullAccess() {
        let (router, local) = makeRouter()
        XCTAssertEqual(router.type(.text("A")), .insertedLocally)
        XCTAssertEqual(local.inserted, ["A"])
    }

    func testReturnInsertsALineBreak() {
        let (router, local) = makeRouter()
        XCTAssertEqual(router.type(.returnKey), .insertedLocally)
        XCTAssertEqual(local.inserted, ["\n"])
    }

    func testBackspaceDeletesLocally() {
        let (router, local) = makeRouter()
        XCTAssertEqual(router.type(.backspace), .insertedLocally)
        XCTAssertEqual(local.deleteCount, 1); XCTAssertEqual(local.inserted, [])
    }

    func testTypedKeysMapToTheWireEvents() {
        XCTAssertEqual(TypedKey.text("é").eventKind, .text("é"))
        XCTAssertEqual(TypedKey.returnKey.eventKind, .returnKey)
        XCTAssertEqual(TypedKey.backspace.eventKind, .backspace)
    }
}
