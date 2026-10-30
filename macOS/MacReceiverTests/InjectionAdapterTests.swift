import CoreGraphics
import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

/// Pure adapter pieces only. Nothing here posts events, needs Accessibility trust or touches the input source.
@MainActor
final class InjectionAdapterTests: XCTestCase {
    private func unicode(of event: CGEvent) -> String {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 64)
        event.keyboardGetUnicodeString(maxStringLength: 64, actualStringLength: &length, unicodeString: &buffer)
        return String(utf16CodeUnits: buffer, count: length)
    }

    private final class RecordingPoster: EventPosting {
        var batches: [[CGEvent]] = []
        func post(_ events: [CGEvent]) { batches.append(events) }
    }

    // MARK: Test insert focus recheck

    @MainActor private final class FakeSource: InputSourceControlling {
        var current: String
        init(_ current: String) { self.current = current }
        func currentID() -> String { current }
        func select(_ id: String) -> Bool { current = id; return true }
    }

    @MainActor private final class FakeComposing: CompositionControlling {
        func state() -> CompositionState { .composing }
        func cancel() {}
    }

    private func testInsert(
        reads: [FocusReadResult], current: String = InputSourceSwitcher.asciiID, composition: CompositionControlling? = nil
    ) -> (TestInsertController, RecordingPoster, InputSourceNotice, InputSourceSwitcher) {
        let poster = RecordingPoster()
        let monitor = FocusMonitor(reader: ScriptedFocusReader(reads), environment: FocusFixtures.environment())
        let notice = InputSourceNotice()
        let switcher = InputSourceSwitcher(controller: FakeSource(current), composition: composition, settle: { _ in })
        let controller = TestInsertController(
            focus: monitor,
            injector: TextInjector(poster: poster),
            switcher: switcher,
            defaults: UserDefaults(suiteName: "rk.tests.\(UUID().uuidString)")!,
            notice: notice
        )
        return (controller, poster, notice, switcher)
    }

    func testTestInsertRechecksFocusAfterGate() async {
        let (controller, poster, _, switcher) = testInsert(reads: [FocusFixtures.elementA, FocusFixtures.elementB])
        // Another call holds the switcher's gate; the test insert passes its first check and then waits behind it.
        let holder = Task { await switcher.withASCII { try? await Task.sleep(for: .milliseconds(300)) } }
        try? await Task.sleep(for: .milliseconds(50))
        await controller.run(TestInsertItem.all[0])
        _ = await holder.value
        XCTAssertEqual(poster.batches.count, 0, "focus moved while queued behind the gate, nothing may be typed")
        XCTAssertEqual(controller.status, "未插入：焦點已改變")
    }

    func testTestInsertRechecksBeforeEscapeWhenFocusMovesBehindTheGate() async {
        let (controller, poster, _, _) = testInsert(
            reads: [FocusFixtures.elementA, FocusFixtures.elementB], current: "com.apple.inputmethod.TCIM.Zhuyin",
            composition: FakeComposing())
        await controller.run(TestInsertItem.all[0])
        XCTAssertEqual(poster.batches.count, 0)
        XCTAssertEqual(controller.status, "未插入：焦點已改變")
    }

    func testTestInsertTypesWhenFocusHolds() async {
        let (controller, poster, _, _) = testInsert(reads: [FocusFixtures.elementA])
        await controller.run(TestInsertItem.all[0])
        XCTAssertEqual(poster.batches.count, 1)
        XCTAssertTrue(controller.status.hasPrefix("已插入"))
    }

    // MARK: Editable classifier

    func testEditableRolesAreEditable() {
        for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
            XCTAssertTrue(FocusMonitor.isEditable(role: role, valueSettable: false), role)
        }
    }

    func testNonTextRoleNeedsSettableValue() {
        XCTAssertFalse(FocusMonitor.isEditable(role: "AXButton", valueSettable: false))
        XCTAssertFalse(FocusMonitor.isEditable(role: nil, valueSettable: false))
        XCTAssertTrue(FocusMonitor.isEditable(role: "AXGroup", valueSettable: true))
        XCTAssertTrue(FocusMonitor.isEditable(role: nil, valueSettable: true))
    }

    // MARK: Event construction

    func testTextEventsCarryUnicodeOnKeyDownAndKeyUp() throws {
        for text in ["A", "香港", "👨‍👩‍👧‍👦", "café"] {
            let events = TextInjector.makeTextEvents(text)
            XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp], text)
            for event in events {
                XCTAssertEqual(unicode(of: event), text)
                XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 0)
                XCTAssertTrue(event.flags.isEmpty)
            }
        }
    }

    func testEmptyTextBuildsNoEvents() { XCTAssertTrue(TextInjector.makeTextEvents("").isEmpty) }

    func testBackspaceAndReturnUseExpectedVirtualKeys() {
        XCTAssertEqual(TextInjector.backspaceKey, 51)
        XCTAssertEqual(TextInjector.returnKey, 36)
        for (key, code) in [(TextInjector.backspaceKey, 51), (TextInjector.returnKey, 36)] {
            let events = TextInjector.makeKeyEvents(virtualKey: key)
            XCTAssertEqual(events.map(\.type), [.keyDown, .keyUp])
            XCTAssertTrue(events.allSatisfy { $0.getIntegerValueField(.keyboardEventKeycode) == Int64(code) })
        }
    }

    // MARK: Posting goes through the seam

    func testInsertChunksLongTextIntoSeparateEventPairs() {
        let poster = RecordingPoster()
        let injector = TextInjector(poster: poster)
        let outcome = injector.insert(TestInsertItem.o5Text)
        XCTAssertEqual(outcome.posted, 2)
        XCTAssertEqual(poster.batches.count, 2)
        XCTAssertEqual(poster.batches.map { unicode(of: $0[0]) }, ["ABCDEFGHIJKLMNOPQRST", "UVWXYZ0123"])
    }

    func testUnchunkedInsertPostsOneEventPair() {
        let poster = RecordingPoster()
        XCTAssertTrue(TextInjector(poster: poster).insertUnchunked(TestInsertItem.o5Text))
        XCTAssertEqual(poster.batches.count, 1)
        XCTAssertEqual(unicode(of: poster.batches[0][0]), TestInsertItem.o5Text)
    }

    func testInsertStopsAtFirstFailedChunk() {
        let poster = RecordingPoster()
        var built = 0
        let injector = TextInjector(poster: poster, buildTextEvents: { chunk in
            built += 1
            // Chunk 2 of 3 fails to build.
            return built == 2 ? [] : TextInjector.makeTextEvents(chunk)
        })
        let text = String(repeating: "a", count: 20) + String(repeating: "b", count: 20) + "c"
        let outcome = injector.insert(text)
        XCTAssertEqual(outcome, InsertOutcome(posted: 1, total: 3))
        XCTAssertFalse(outcome.complete)
        XCTAssertEqual(built, 2, "third chunk must never be attempted")
        XCTAssertEqual(poster.batches.count, 1)
    }

    func testInsertReportsCompleteWhenAllChunksPosted() {
        let outcome = TextInjector(poster: RecordingPoster()).insert(TestInsertItem.o5Text)
        XCTAssertEqual(outcome, InsertOutcome(posted: 2, total: 2))
        XCTAssertTrue(outcome.complete)
    }

    func testFocusReadSkippedForOwnProcessUntrustedOrNoApp() {
        XCTAssertTrue(FocusMonitor.shouldReadFocus(trusted: true, pid: 200, ownPID: 100))
        XCTAssertFalse(FocusMonitor.shouldReadFocus(trusted: true, pid: 100, ownPID: 100))
        XCTAssertFalse(FocusMonitor.shouldReadFocus(trusted: false, pid: 200, ownPID: 100))
        XCTAssertFalse(FocusMonitor.shouldReadFocus(trusted: true, pid: 0, ownPID: 100))
    }

    func testBackspaceAndReturnPostOnePairEach() {
        let poster = RecordingPoster()
        let injector = TextInjector(poster: poster)
        injector.backspace()
        injector.returnKeyPress()
        XCTAssertEqual(poster.batches.map { $0[0].getIntegerValueField(.keyboardEventKeycode) }, [51, 36])
    }

    // MARK: Menu content

    func testTestInsertItemsMatchTheAcceptanceSet() {
        XCTAssertEqual(TestInsertItem.all.prefix(5).map(\.text), ["A", "Hello", "香港", "👨‍👩‍👧‍👦", "café"])
        XCTAssertTrue(TestInsertItem.all.prefix(5).allSatisfy(\.chunked))
        let o5 = TestInsertItem.all[5]
        XCTAssertEqual(o5.text.count, 30)
        XCTAssertFalse(o5.chunked)
    }

    func testFocusLineWording() {
        func snap(ax: Bool = true, editable: Bool, name: String? = "TextEdit", epoch: UInt64 = 12) -> FocusSnapshot {
            FocusSnapshot(axTrusted: ax, frontmostPID: 1, appName: name, editable: editable, epoch: epoch)
        }
        XCTAssertEqual(FocusMenuText.line(snap(editable: true)), "焦點：TextEdit（可編輯，epoch 12）")
        XCTAssertEqual(FocusMenuText.line(snap(editable: false, name: "Finder", epoch: 3)), "焦點：Finder（不可編輯，epoch 3）")
        XCTAssertEqual(FocusMenuText.line(snap(ax: false, editable: false)), "輔助使用未授權")
        XCTAssertEqual(FocusMenuText.line(nil), "焦點：讀取中")
    }

    func testEveryRefusalHasADistinctReason() {
        let reasons = [InjectionDecision.notAuthorized, .noFocus, .staleFocus].map(FocusMenuText.reason)
        XCTAssertEqual(Set(reasons).count, 3)
    }
}
