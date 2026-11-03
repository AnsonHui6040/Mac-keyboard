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
        // A shared start keeps this from being a slid window; the 80 trailing characters are what exceeds the cap.
        _ = mirror.observe(before: "x" + String(repeating: "a", count: 80), after: "", at: 0)
        XCTAssertEqual(mirror.observe(before: "x", after: "", at: 1), .tooLarge)
        XCTAssertEqual(mirror.counters.resets, 1)
        // The baseline is the new snapshot, so the next small change is sent normally.
        XCTAssertEqual(mirror.observe(before: "xy", after: "", at: 2), .events([.text("y")]))
    }

    func testExactlyTheCapsAreStillSent() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "x" + String(repeating: "a", count: 50), after: "", at: 0)
        guard case .events(let events) = mirror.observe(before: "x" + String(repeating: "b", count: 500), after: "", at: 1) else {
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

    func testRebaselineClearsThePendingOwnEditWindow() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "ab", after: "", at: 0)
        mirror.noteOwnEdit(at: 1)
        mirror.rebaseline(before: "ab", after: "", documentId: nil)
        XCTAssertEqual(mirror.observe(before: "abc", after: "", at: 1.1), .events([.text("c")]))
    }

    // MARK: Text after the cursor

    func testOnlyTextAfterTheCursorChangingSendsNothingAndMovesTheBaseline() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "abc", after: "def", at: 0)
        XCTAssertEqual(mirror.observe(before: "abc", after: "dXef", at: 1), .unchanged)
        XCTAssertEqual(mirror.counters.externalGrowths, 0)
        // The next real edit is measured from the new snapshot.
        XCTAssertEqual(mirror.observe(before: "abcZ", after: "dXef", at: 2), .events([.text("Z")]))
    }

    // MARK: Another document

    func testNewDocumentIdentifierOnlyResetsTheBaseline() {
        let first = UUID()
        let second = UUID()
        var mirror = DictationMirror()
        _ = mirror.observe(before: "第一個欄位的內容", after: "", documentId: first, at: 0)
        XCTAssertEqual(
            mirror.observe(before: "別的欄位", after: "", documentId: second, at: 1), .documentChanged)
        XCTAssertEqual(mirror.counters.documentChanges, 1)
        XCTAssertEqual(mirror.counters.externalGrowths, 0)
        // From here the new document is the reference.
        XCTAssertEqual(
            mirror.observe(before: "別的欄位嗎", after: "", documentId: second, at: 2), .events([.text("嗎")]))
    }

    func testSameDocumentIdentifierBehavesAsBefore() {
        let id = UUID()
        var mirror = DictationMirror()
        _ = mirror.observe(before: "ab", after: "", documentId: id, at: 0)
        XCTAssertEqual(mirror.observe(before: "abc", after: "", documentId: id, at: 1), .events([.text("c")]))
    }

    func testRebaselineRemembersTheDocumentIdentifier() {
        let first = UUID()
        var mirror = DictationMirror()
        mirror.rebaseline(before: "ab", after: "", documentId: first)
        XCTAssertEqual(mirror.observe(before: "abc", after: "", documentId: UUID(), at: 1), .documentChanged)
    }

    // MARK: Unknown document identifier (iOS answers nil in some fields)

    func testNilIdentifierAfterAKnownOneIsNotAFieldChange() {
        let id = UUID()
        var mirror = DictationMirror()
        _ = mirror.observe(before: "ab", after: "", documentId: id, at: 0)
        XCTAssertEqual(mirror.observe(before: "abc", after: "", documentId: nil, at: 1), .events([.text("c")]))
        XCTAssertEqual(mirror.counters.documentChanges, 0)
    }

    func testKnownIdentifierAfterANilOneIsNotAFieldChange() {
        let id = UUID()
        var mirror = DictationMirror()
        _ = mirror.observe(before: "ab", after: "", documentId: nil, at: 0)
        XCTAssertEqual(mirror.observe(before: "abc", after: "", documentId: id, at: 1), .events([.text("c")]))
        XCTAssertEqual(mirror.counters.documentChanges, 0)
    }

    func testTheKnownIdentifierSurvivesANilReading() {
        let first = UUID()
        let second = UUID()
        var mirror = DictationMirror()
        _ = mirror.observe(before: "ab", after: "", documentId: first, at: 0)
        _ = mirror.observe(before: "ab", after: "", documentId: nil, at: 1)
        // Two real, different identifiers are still a field change.
        XCTAssertEqual(mirror.observe(before: "xy", after: "", documentId: second, at: 2), .documentChanged)
    }

    func testNilIdentifierTwiceBehavesAsBefore() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "ab", after: "", documentId: nil, at: 0)
        XCTAssertEqual(mirror.observe(before: "abc", after: "", documentId: nil, at: 1), .events([.text("c")]))
        XCTAssertEqual(mirror.counters.documentChanges, 0)
    }

    // MARK: A window that slid or jumped

    func testReplacingTheWholeLongWindowIsUntrusted() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "abcdefghij", after: "", at: 0)
        XCTAssertEqual(mirror.observe(before: "klmnopqrst", after: "", at: 1), .untrusted)
        XCTAssertEqual(mirror.counters.untrusted, 1)
        XCTAssertEqual(mirror.counters.externalGrowths, 0)
        // The baseline is the new window.
        XCTAssertEqual(mirror.observe(before: "klmnopqrstu", after: "", at: 2), .events([.text("u")]))
    }

    func testReplacingAShortWindowCompletelyIsStillSent() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "abcdefghi", after: "", at: 0)
        XCTAssertEqual(mirror.observe(before: "xyz", after: "", at: 1), .events(Array(repeating: .backspace, count: 9) + [.text("xyz")]))
    }

    func testLongWindowWithASharedPrefixIsStillSent() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "abcdefghijkl", after: "", at: 0)
        XCTAssertEqual(
            mirror.observe(before: "abcdefghijkXY", after: "", at: 1), .events([.backspace, .text("XY")]))
    }

    func testSlidingWindowThatKeepsNoPrefixIsUntrustedNotDeleted() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "0123456789ABCDEF", after: "", at: 0)
        // The oldest characters scrolled out of the window, so nothing at the start matches.
        XCTAssertEqual(mirror.observe(before: "456789ABCDEFGH", after: "", at: 1), .untrusted)
    }

    // MARK: No baseline

    func testNilContextDoesNotSetABaseline() {
        var mirror = DictationMirror()
        XCTAssertFalse(mirror.rebaseline(before: nil, after: nil, documentId: UUID()))
        XCTAssertFalse(mirror.hasBaseline)
        // The first change then only sets the baseline, even though text is already there.
        XCTAssertEqual(mirror.observe(before: "既有的整段文字", after: "", at: 0), .baselineSet)
    }

    func testNoteDidChangeCountsWithoutTouchingTheBaseline() {
        var mirror = DictationMirror()
        mirror.noteDidChange()
        XCTAssertEqual(mirror.counters.didChangeCalls, 1)
        XCTAssertFalse(mirror.hasBaseline)
    }

    func testRebaselineWithTextSetsABaseline() {
        var mirror = DictationMirror()
        XCTAssertTrue(mirror.rebaseline(before: "", after: nil, documentId: nil))
        XCTAssertTrue(mirror.hasBaseline)
    }

    // MARK: Appearing again

    func testAppearanceWithoutABaselineDoesNothing() {
        var mirror = DictationMirror()
        XCTAssertNil(mirror.observeOnAppear(before: "既有", after: "", documentId: nil, at: 0))
        XCTAssertFalse(mirror.hasBaseline)
        XCTAssertEqual(mirror.counters.didChangeCalls, 0)
    }

    func testAppearanceWithNilTextBeforeTheCursorIsSkippedAndKeepsTheBaseline() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "ab", after: "", at: 0)
        let nilBefore: String? = nil
        XCTAssertNil(mirror.observeOnAppear(before: nilBefore, after: nil, documentId: nil, at: 1))
        XCTAssertEqual(mirror.counters.didChangeCalls, 1)
        // The old baseline is untouched, so the next real change is measured from "ab".
        XCTAssertEqual(mirror.observe(before: "abc", after: "", at: 2), .events([.text("c")]))
    }

    func testBaselineSetIsCounted() {
        var mirror = DictationMirror()
        XCTAssertEqual(mirror.counters.baselines, 0)
        _ = mirror.observe(before: "abc", after: "", at: 0)
        XCTAssertEqual(mirror.counters.baselines, 1)
        _ = mirror.observe(before: "abcd", after: "", at: 1)
        XCTAssertEqual(mirror.counters.baselines, 1)
    }

    func testRebaselineAndSkippedNilAreNotCountedAsBaselineSets() {
        var mirror = DictationMirror()
        mirror.rebaseline(before: "a", after: "", documentId: nil)
        mirror.noteDidChange()
        XCTAssertEqual(mirror.counters.baselines, 0)
    }

    func testAppearanceWithABaselineComparesOnceWithoutCountingADidChange() {
        var mirror = DictationMirror()
        _ = mirror.observe(before: "ab", after: "", at: 0)
        XCTAssertEqual(mirror.observeOnAppear(before: "abc", after: "", documentId: nil, at: 1), .events([.text("c")]))
        XCTAssertEqual(mirror.counters.didChangeCalls, 1)
        XCTAssertEqual(mirror.observeOnAppear(before: "abc", after: "", documentId: nil, at: 2), .unchanged)
    }

    // MARK: Switch lease

    func testLeaseHoldsForThirtyMinutes() {
        XCTAssertEqual(DictationMirror.leaseSeconds, 30 * 60)
        XCTAssertTrue(DictationMirror.isLeaseValid(startedAt: 1_000, now: 1_000 + 1_800))
        XCTAssertFalse(DictationMirror.isLeaseValid(startedAt: 1_000, now: 1_000 + 1_801))
    }

    func testLeaseIsInvalidWithoutAStartTimeOrWithAClockThatWentBack() {
        XCTAssertFalse(DictationMirror.isLeaseValid(startedAt: nil, now: 5))
        XCTAssertFalse(DictationMirror.isLeaseValid(startedAt: 100, now: 50))
    }

    // MARK: 2026-10-31 device observation: the draft no longer ends with the text iOS revises

    private enum Landed: Equatable { case draft, mac, skipped, dropped }

    /// What the controller does with one difference: in draft mode a difference with backspaces is applied only when the
    /// draft cursor sits right behind the text being deleted; otherwise the whole difference is dropped.
    @discardableResult
    private func apply(
        _ outcome: DictationMirror.Outcome, mirror: inout DictationMirror, draft: inout DraftBuffer,
        transmit: TransmitMode = .draft, ready: Bool = true, blocked: Bool = false
    ) -> Landed? {
        guard case .events(let events) = outcome else { return nil }
        if DictationSync.isDropped(events: events, blocked: blocked) { return .dropped }
        let toDraft = DictationSync.goesToDraft(transmit: transmit, draftEmpty: draft.isEmpty)
        // Instant with an empty draft: straight to the Mac when it is ready, otherwise the router drops every key.
        guard toDraft else { return ready ? .mac : .dropped }
        if events.contains(.backspace), !DictationSync.draftAccepts(deleted: mirror.lastDeleted, draft: draft) {
            mirror.noteDraftSkipped()
            return .skipped
        }
        for event in events {
            switch event {
            case .text(let text): _ = draft.insert(text)
            case .backspace: draft.deleteBackward()
            default: break
            }
        }
        return .draft
    }

    /// "吃法" -> "吃法 good" (iOS's guess) in the draft, ready for the revision "吃法 Good day".
    private func draftWithAGuess(_ mirror: inout DictationMirror) -> DraftBuffer {
        var draft = DraftBuffer()
        mirror.rebaseline(before: "", after: "")
        apply(mirror.observe(before: "吃法", after: "", at: 0), mirror: &mirror, draft: &draft)
        apply(mirror.observe(before: "吃法 good", after: "", at: 1), mirror: &mirror, draft: &draft)
        return draft
    }

    func testTheDeletedTextIsOfferedForTheDraftCheck() {
        var mirror = DictationMirror()
        mirror.rebaseline(before: "今天天氣", after: "")
        XCTAssertEqual(mirror.lastDeleted, "")
        _ = mirror.observe(before: "今天的天氣", after: "", at: 1)
        XCTAssertEqual(mirror.lastDeleted, "天氣")
        // A pure growth deletes nothing, and a difference that is not sent leaves nothing behind.
        _ = mirror.observe(before: "今天的天氣好", after: "", at: 2)
        XCTAssertEqual(mirror.lastDeleted, "")
    }

    /// The case that produced "Good daygood" before: the draft cursor was moved away from the guess.
    func testReviseAfterTheDraftCursorMovedAwayIsDroppedWhole() {
        var mirror = DictationMirror()
        var draft = draftWithAGuess(&mirror)
        XCTAssertEqual(draft.text, "吃法 good")
        for _ in 0..<4 { draft.moveLeft() }
        let outcome = mirror.observe(before: "吃法 Good day", after: "", at: 2)
        XCTAssertEqual(apply(outcome, mirror: &mirror, draft: &draft), .skipped)
        // Nothing is eaten, nothing is doubled; the new text of the revision is dropped with it.
        XCTAssertEqual(draft.text, "吃法 good")
        XCTAssertEqual(mirror.counters.draftSkipped, 1)
    }

    func testReviseAfterMovingTheCursorAwayAndBackIsApplied() {
        var mirror = DictationMirror()
        var draft = draftWithAGuess(&mirror)
        for _ in 0..<4 { draft.moveLeft() }
        for _ in 0..<4 { draft.moveRight() }
        let outcome = mirror.observe(before: "吃法 Good day", after: "", at: 2)
        XCTAssertEqual(apply(outcome, mirror: &mirror, draft: &draft), .draft)
        XCTAssertEqual(draft.text, "吃法 Good day")
        XCTAssertEqual(mirror.counters.draftSkipped, 0)
    }

    func testReviseAfterTypingAndDeletingInTheDraftIsApplied() {
        var mirror = DictationMirror()
        var draft = draftWithAGuess(&mirror)
        _ = draft.insert("x")
        draft.deleteBackward()
        let outcome = mirror.observe(before: "吃法 Good day", after: "", at: 2)
        XCTAssertEqual(apply(outcome, mirror: &mirror, draft: &draft), .draft)
        XCTAssertEqual(draft.text, "吃法 Good day")
    }

    func testReviseAfterTypingInTheDraftIsDroppedBecauseTheTextNoLongerLinesUp() {
        var mirror = DictationMirror()
        var draft = draftWithAGuess(&mirror)
        _ = draft.insert("x")
        let outcome = mirror.observe(before: "吃法 Good day", after: "", at: 2)
        XCTAssertEqual(apply(outcome, mirror: &mirror, draft: &draft), .skipped)
        XCTAssertEqual(draft.text, "吃法 goodx")
    }

    func testGrowthIsAlwaysAddedAtTheDraftCursor() {
        var mirror = DictationMirror()
        var draft = DraftBuffer()
        mirror.rebaseline(before: "", after: "")
        apply(mirror.observe(before: "吃法", after: "", at: 0), mirror: &mirror, draft: &draft)
        draft.moveLeft()
        let outcome = mirror.observe(before: "吃法 good", after: "", at: 1)
        XCTAssertEqual(outcome, .events([.text(" good")]))
        XCTAssertEqual(apply(outcome, mirror: &mirror, draft: &draft), .draft)
        XCTAssertEqual(draft.text, "吃 good法")
    }

    func testInstantModeIsNotCheckedAgainstTheDraftEvenAfterSending() {
        var mirror = DictationMirror()
        var draft = DraftBuffer()
        mirror.rebaseline(before: "", after: "")
        // Instant mode with the Mac ready and an empty draft (as right after 傳送): the difference goes to the Mac.
        let first = mirror.observe(before: "吃法 good", after: "", at: 0)
        XCTAssertEqual(apply(first, mirror: &mirror, draft: &draft, transmit: .instant, ready: true), .mac)
        let revision = mirror.observe(before: "吃法 Good day", after: "", at: 1)
        XCTAssertEqual(apply(revision, mirror: &mirror, draft: &draft, transmit: .instant, ready: true), .mac)
        XCTAssertEqual(mirror.counters.draftSkipped, 0)
    }

    func testWhereADifferenceGoes() {
        XCTAssertTrue(DictationSync.goesToDraft(transmit: .draft, draftEmpty: true))
        XCTAssertTrue(DictationSync.goesToDraft(transmit: .instant, draftEmpty: false))
        XCTAssertFalse(DictationSync.goesToDraft(transmit: .instant, draftEmpty: true))
    }

    func testABlockedMacRefusesADifferenceThatTypesText() {
        XCTAssertTrue(DictationSync.isDropped(events: [.text("p")], blocked: true))
        XCTAssertTrue(DictationSync.isDropped(events: [.backspace, .text("p")], blocked: true))
        XCTAssertTrue(DictationSync.isDropped(events: [.returnKey], blocked: true))
        // A pure deletion may still trim existing draft text; the router decides whether there is any.
        XCTAssertFalse(DictationSync.isDropped(events: [.backspace, .backspace], blocked: true))
        XCTAssertFalse(DictationSync.isDropped(events: [.backspace, .text("p")], blocked: false))
    }

    func testBlockedDictationStoresNothingAndNothingIsCountedAsDraftedOrSent() {
        var mirror = DictationMirror()
        var draft = DraftBuffer()
        mirror.rebaseline(before: "", after: "")
        let landed = apply(
            mirror.observe(before: "secret", after: "", at: 0), mirror: &mirror, draft: &draft, transmit: .draft, ready: false,
            blocked: true)
        XCTAssertEqual(landed, .dropped)
        XCTAssertTrue(draft.isEmpty)
        XCTAssertEqual(mirror.counters.eventsDrafted, 0); XCTAssertEqual(mirror.counters.eventsSent, 0)
        // The baseline moved with the text, so the next difference is measured from what the field holds now.
        XCTAssertEqual(mirror.observe(before: "secret", after: "", at: 1), .unchanged)
        guard case .events(let more) = mirror.observe(before: "secret!", after: "", at: 2) else { return XCTFail("expected events") }
        XCTAssertEqual(more, [.text("!")])
    }

    func testNotReadyInstantEmptyDraftDictationIsDroppedNotDrafted() {
        var mirror = DictationMirror()
        var draft = DraftBuffer()
        mirror.rebaseline(before: "", after: "")
        let landed = apply(
            mirror.observe(before: "hi", after: "", at: 0), mirror: &mirror, draft: &draft, transmit: .instant, ready: false)
        XCTAssertEqual(landed, .dropped)
        XCTAssertTrue(draft.isEmpty)
    }

    func testTheDraftCheckComparesCharactersBeforeTheCursor() {
        var draft = DraftBuffer()
        _ = draft.insert("吃法 good")
        XCTAssertTrue(DictationSync.draftAccepts(deleted: "", draft: draft))
        XCTAssertTrue(DictationSync.draftAccepts(deleted: "good", draft: draft))
        XCTAssertFalse(DictationSync.draftAccepts(deleted: "goods", draft: draft))
        draft.moveLeft()
        XCTAssertFalse(DictationSync.draftAccepts(deleted: "good", draft: draft))
        XCTAssertTrue(DictationSync.draftAccepts(deleted: "goo", draft: draft))
        // An empty draft has nothing to delete.
        XCTAssertFalse(DictationSync.draftAccepts(deleted: "a", draft: DraftBuffer()))
    }

    // MARK: D18 sync conditions

    func testSyncRunsOnlyInRemoteModeWithTheSettingOn() {
        XCTAssertTrue(DictationSync.isActive(mode: .remote, storedSetting: true))
        XCTAssertFalse(DictationSync.isActive(mode: .remote, storedSetting: false))
        XCTAssertFalse(DictationSync.isActive(mode: .local, storedSetting: true))
        XCTAssertFalse(DictationSync.isActive(mode: .local, storedSetting: false))
    }

    func testTheSettingDefaultsToOnWhenNothingWasStored() {
        XCTAssertTrue(DictationSync.isEnabled(stored: nil))
        XCTAssertTrue(DictationSync.isActive(mode: .remote, storedSetting: nil))
        XCTAssertTrue(DictationSync.isEnabled(stored: true))
        XCTAssertFalse(DictationSync.isEnabled(stored: false))
        // Something that is not a Bool (a damaged suite) is also treated as not set.
        XCTAssertTrue(DictationSync.isEnabled(stored: "no"))
    }

    func testTheAppGroupKeyIsStable() {
        XCTAssertEqual(AppGroup.Key.dictationSync, "rk.dictationSync")
    }

    // MARK: First baseline of a keyboard that was just built

    func testALoadedTextIsAlwaysTheBaseline() {
        for phase in [DictationMirror.BaselinePhase.willChange, .didChangeOrAppear] {
            XCTAssertEqual(DictationMirror.initialBaselineText(before: "你好", hasText: true, phase: phase), "你好")
            XCTAssertEqual(DictationMirror.initialBaselineText(before: "", hasText: false, phase: phase), "")
        }
    }

    func testOnlyTheWillChangePathMayTakeNilAsAnEmptyField() {
        // textWillChange: the field is about to be edited; nil and "has no text" is an empty field.
        XCTAssertEqual(
            DictationMirror.initialBaselineText(before: nil, hasText: false, phase: .willChange), "")
        // nil and the field says it has text: the cursor is at the start or the field is not loaded. Never guess.
        XCTAssertNil(DictationMirror.initialBaselineText(before: nil, hasText: true, phase: .willChange))
        // textDidChange and viewDidAppear: the field may simply not be loaded yet, whatever hasText says.
        XCTAssertNil(DictationMirror.initialBaselineText(before: nil, hasText: false, phase: .didChangeOrAppear))
        XCTAssertNil(DictationMirror.initialBaselineText(before: nil, hasText: true, phase: .didChangeOrAppear))
    }
}
