import XCTest
@testable import RemoteKeyboardCore

final class DictationMirrorTests: XCTestCase {
    func testFirstSnapshotOnlySetsTheBaseline() {
        var mirror = DictationMirror()
        XCTAssertEqual(mirror.observe(before: "你好", after: "", at: 0), .baselineSet)
        XCTAssertEqual(mirror.counters.didChangeCalls, 1)
        XCTAssertEqual(mirror.counters.externalGrowths, 0)
    }

    func testAppendedDictationBecomesTextAndCountsAsAGrowth() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "你好", after: "", at: 0)
        XCTAssertEqual(mirror.observe(before: "你好嗎", after: "", at: 1), .events([.text("嗎")]))
        XCTAssertEqual(mirror.counters.externalGrowths, 1)
        XCTAssertEqual(mirror.counters.lastBackspaces, 0)
        XCTAssertEqual(mirror.counters.lastCharacters, 1)
    }

    func testCorrectionBecomesBackspacesThenText() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "今天天氣", after: "", at: 0)
        XCTAssertEqual(
            mirror.observe(before: "今天的天氣", after: "", at: 1), .events([.backspace, .backspace, .text("的天氣")]))
        XCTAssertEqual(mirror.counters.lastBackspaces, 2)
        XCTAssertEqual(mirror.counters.lastCharacters, 3)
    }

    func testUnchangedSnapshotProducesNothing() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "abc", after: "d", at: 0)
        XCTAssertEqual(mirror.observe(before: "abc", after: "d", at: 1), .unchanged)
    }

    func testCursorMoveIsNotATextChange() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "abcdef", after: "", at: 0)
        // The user tapped between c and d: the text is the same, only the split moved.
        XCTAssertEqual(mirror.observe(before: "abc", after: "def", at: 1), .cursorMoved)
        XCTAssertEqual(mirror.counters.externalGrowths, 0)
        // After the move, dictation inserts at the cursor.
        XCTAssertEqual(mirror.observe(before: "abcXY", after: "def", at: 2), .events([.text("XY")]))
    }

    func testOwnEditWithinTheWindowIsIgnoredAndRebaselined() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "ab", after: "", at: 0)
        mirror.noteOwnEdit(at: 1)
        XCTAssertEqual(mirror.observe(before: "abc", after: "", at: 1.2), .ownEdit)
        XCTAssertEqual(mirror.counters.externalGrowths, 0)
        // The baseline moved, so the next real change is measured from "abc".
        XCTAssertEqual(mirror.observe(before: "abcd", after: "", at: 3), .events([.text("d")]))
    }

    func testOwnEditWindowExpires() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "ab", after: "", at: 0)
        mirror.noteOwnEdit(at: 1)
        XCTAssertEqual(mirror.observe(before: "abc", after: "", at: 1 + DictationMirror.ownEditWindow + 0.1), .events([.text("c")]))
    }

    func testTooManyBackspacesResetsInsteadOfSending() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: String(repeating: "a", count: 80), after: "", at: 0)
        XCTAssertEqual(mirror.observe(before: "", after: "", at: 1), .tooLarge)
        XCTAssertEqual(mirror.counters.resets, 1)
        // The baseline is the new (empty) snapshot, so the next small change is sent normally.
        XCTAssertEqual(mirror.observe(before: "x", after: "", at: 2), .events([.text("x")]))
    }

    func testExactlyTheCapsAreStillSent() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: String(repeating: "a", count: 50), after: "", at: 0)
        guard case .events(let events) = mirror.observe(before: String(repeating: "b", count: 500), after: "", at: 1) else {
            return XCTFail("expected events")
        }
        XCTAssertEqual(events.count, 51)
        XCTAssertEqual(mirror.counters.lastBackspaces, 50)
        XCTAssertEqual(mirror.counters.lastCharacters, 500)
    }

    func testTooManyCharactersResets() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "", after: "", at: 0)
        XCTAssertEqual(mirror.observe(before: String(repeating: "x", count: 501), after: "", at: 1), .tooLarge)
    }

    func testRebaselineDropsAnyPendingDifference() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "abc", after: "", at: 0)
        mirror.rebaseline(before: "xyz", after: "")
        XCTAssertEqual(mirror.observe(before: "xyzw", after: "", at: 1), .events([.text("w")]))
    }

    func testHasBaselineOnlyAfterASnapshot() {
        var mirror = DictationMirror()
        XCTAssertFalse(mirror.hasBaseline)
        mirror.rebaseline(before: "a", after: "")
        XCTAssertTrue(mirror.hasBaseline)
    }

    func testSendAndAckCounters() {
        var mirror = DictationMirror()
        mirror.noteWillChange()
        mirror.noteWillChange()
        mirror.noteSent(2)
        mirror.noteAcked()
        XCTAssertEqual(mirror.counters.willChangeCalls, 2)
        XCTAssertEqual(mirror.counters.eventsSent, 2)
        XCTAssertEqual(mirror.counters.eventsAcked, 1)
    }

    func testDraftedAndViewCountersAndRestoredCounters() {
        var mirror = DictationMirror()
        mirror.noteDrafted(3)
        mirror.noteAppeared()
        mirror.noteDisappeared()
        mirror.noteDisappeared()
        XCTAssertEqual(mirror.counters.eventsDrafted, 3)
        XCTAssertEqual(mirror.counters.appearances, 1)
        XCTAssertEqual(mirror.counters.disappearances, 2)
        // A rebuilt keyboard keeps the numbers; the text baseline is not part of them.
        let data = try? JSONEncoder().encode(mirror.counters)
        let restored = data.flatMap { try? JSONDecoder().decode(DictationMirror.Counters.self, from: $0) }
        var rebuilt = DictationMirror(counters: restored ?? DictationMirror.Counters())
        XCTAssertEqual(rebuilt.counters.disappearances, 2)
        XCTAssertEqual(rebuilt.observe(before: "ab", after: "", at: 0), .baselineSet)
    }

    func testResetClearsBaselineAndCounters() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "a", after: "", at: 0)
        _ = mirror.observe(before: "ab", after: "", at: 1)
        mirror = DictationMirror()
        XCTAssertEqual(mirror.counters.externalGrowths, 0)
        XCTAssertEqual(mirror.observe(before: "ab", after: "", at: 2), .baselineSet)
    }
}
