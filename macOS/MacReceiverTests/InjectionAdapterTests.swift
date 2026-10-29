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
        let chunks = injector.insert(TestInsertItem.o5Text)
        XCTAssertEqual(chunks, 2)
        XCTAssertEqual(poster.batches.count, 2)
        XCTAssertEqual(poster.batches.map { unicode(of: $0[0]) }, ["ABCDEFGHIJKLMNOPQRST", "UVWXYZ0123"])
    }

    func testUnchunkedInsertPostsOneEventPair() {
        let poster = RecordingPoster()
        XCTAssertTrue(TextInjector(poster: poster).insertUnchunked(TestInsertItem.o5Text))
        XCTAssertEqual(poster.batches.count, 1)
        XCTAssertEqual(unicode(of: poster.batches[0][0]), TestInsertItem.o5Text)
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
