import XCTest

/// T10 keyboard acceptance, driven from outside the keyboard process on a physical iPhone.
///
/// Run it through `e2e/scripts/t10-device-run.sh`, which also watches the Mac side (TextEdit). Every case is
/// independent: it opens Notes, creates its own new note, taps only inside that empty note's body, brings up the
/// Remote Keyboard in the state it needs, does its steps and asserts what the iPhone shows (Notes body, `rk.draft`,
/// `rk.send`, `rk.transmit`, `rk.mode`, `rk.shift`, `rk.zhEn`). What reached the Mac is checked by the script.
///
/// Only fixed ASCII test strings are typed. Local-mode text is deleted again so Notes drops the empty note.
/// `tearDown` puts the keyboard back to Remote and Instant.
///
/// Preconditions: Mac paired, Receiver armed (開始接收), Full Access on, Remote Keyboard selected, TextEdit focused on
/// the Mac, Notes closed or on its list.
///
/// E2E step map (see `e2e/E2E-T10-KEYBOARD.md`):
/// - `testShiftAndInstant` 2-8
/// - `testRemoteLongPressDelete` 9
/// - `testLocalModeAndLongPressDelete` 10, 11, 12, 13
/// - `testDraftEditing` 14-21
/// - `testInstantWithDraftEditsDraft` 22-25
/// - `testNotReadyGoesToDraft` 26-27
/// - `testModeSwitchKeepsDraft` 29-30
/// - `testSymbolsAndPages` 34-35
/// - `testAccessibilityLabels` 1 (AppGroup line), 38 (labels only; spoken VoiceOver stays manual)
/// - `testPersistence` 28, 37 (without restarting the app)
/// - `testFieldKinds` 32-33 (deferred to T16 manual testing; not in the script's default run; opens a data: URL in
///   Safari's current tab and skips whenever Safari cannot be driven)
/// - `testDraftCap` 31 (deferred to T16 manual testing; not in the default run; skips at once because the DEBUG
///   hook, a 2 s hold on 空白, does not fire under an XCUITest press. A person holding 空白 for 2 s fills the draft.)
@MainActor
final class KeyboardT10UITests: XCTestCase {
    private static let notesID = "com.apple.mobilenotes"
    private static let safariID = "com.apple.mobilesafari"

    private static let local = "本機"
    private static let remote = "遠端"
    private static let instant = "即時"
    private static let draft = "草稿"
    /// What `rk.draft` reports as its value while the draft is empty.
    private static let emptyDraft = "空白"
    private static let shiftOff = "關閉"
    private static let shiftOnce = "下一個字母大寫"
    private static let shiftCaps = "鎖定大寫"
    /// `rk.symbols` is labelled 符號 on a letter page and 返回英文字母 on the symbols page.
    private static let symbolsLabel = "符號"
    private static let backToEnglishLabel = "返回英文字母"

    /// The 30 letters of the remote long-press delete case. The script holds the same string.
    private static let thirtyLetters = "abcdefghijklmnopqrstuvwxyzabcd"
    /// Time for the last key to reach the Mac before the case ends.
    private static let drainSeconds = 2.5
    /// Step 31 is deferred to T16 manual testing; set to false to try the hook under XCUITest again.
    private static let draftCapDeferred = true

    private static let newNoteIdentifiers = ["New Note", "Compose", "newNoteButton"]
    private static let newNoteLabels = ["New Note", "Compose", "新增備忘錄", "新備忘錄", "撰寫"]
    private static let addressIdentifiers = ["URL", "Address", "TabBarItemTitle"]
    private static let addressLabels = ["Address", "URL", "地址", "網址", "搜尋或輸入網址", "搜尋或輸入網站名稱"]
    private static let dismissNames = ["Done", "Cancel", "Hide keyboard", "完成", "取消", "隱藏鍵盤"]
    private static let nextKeyboardNames = ["Next keyboard", "下一個鍵盤"]

    private var notes: XCUIApplication!
    private var events: [String] = []
    private var terminateNotesAfter = false

    override func setUp() async throws {
        continueAfterFailure = false
        notes = XCUIApplication(bundleIdentifier: Self.notesID)
        events = []
        terminateNotesAfter = false
    }

    override func tearDown() async throws {
        attachEvidence()
        restoreRemoteInstant()
        hideKeyboard()
        if terminateNotesAfter, notes.state != .notRunning { notes.terminate() }
    }

    // MARK: Steps 2-8

    /// Shift once, double Shift, Caps off, two slow Shift taps, then hello, 空白 and 換行, all sent live to the Mac.
    func testShiftAndInstant() throws {
        try prepare()
        let status = element("rk.status")
        XCTAssertTrue(status.label.contains("Mac →"), "step 2: status line was '\(status.label)'")
        XCTAssertFalse(element("rk.draft").exists, "step 2: two top rows expected, the draft row is showing")

        // Step 3: one Shift, then A; Shift falls back to off.
        tapID("rk.shift")
        expectValue("rk.shift", Self.shiftOnce, "step 3 after one Shift")
        tapKey("A")
        expectValue("rk.shift", Self.shiftOff, "step 3 after the capital")

        // Step 4: a double tap locks capitals and ABC stays capital.
        element("rk.shift").doubleTap()
        expectValue("rk.shift", Self.shiftCaps, "step 4 after a double tap")
        for letter in ["A", "B", "C"] { tapKey(letter) }
        expectValue("rk.shift", Self.shiftCaps, "step 4 after ABC")

        // Step 5: one more tap releases the lock.
        tapID("rk.shift")
        expectValue("rk.shift", Self.shiftOff, "step 5")
        tapKey("d")

        // Step 6: two taps more than 0.5 s apart do not lock.
        tapID("rk.shift")
        expectValue("rk.shift", Self.shiftOnce, "step 6 first tap")
        Thread.sleep(forTimeInterval: 0.6)
        tapID("rk.shift")
        expectValue("rk.shift", Self.shiftOff, "step 6 slow second tap")
        tapKey("e")

        // Steps 7 and 8: live typing, a space and a line break.
        tapID("rk.space")
        type("hello")
        tapID("rk.return")

        XCTAssertEqual(bodyText(), "", "step 7: the note must stay empty in Remote mode")
        XCTAssertFalse(element("rk.draft").exists, "step 7: live typing must not open the draft row")
        drain()
    }

    // MARK: Step 9

    /// Thirty letters, then 1.0 s on delete. The script checks that 15 to 27 letters are left on the Mac.
    func testRemoteLongPressDelete() throws {
        try prepare()
        type(Self.thirtyLetters)
        mark("THIRTY_TYPED")
        // Let the last letter reach the Mac before the hold, so the deletes cannot overtake it.
        Thread.sleep(forTimeInterval: 1.5)
        element("rk.backspace").press(forDuration: 1.0)
        mark("DELETE_HELD")
        XCTAssertEqual(bodyText(), "", "step 9: the note must stay empty in Remote mode")
        XCTAssertFalse(element("rk.draft").exists, "step 9: live typing must not open the draft row")
        drain()
    }

    // MARK: Steps 10-13

    /// Local mode writes into the Notes body, long-press delete repeats there, and the transmit toggle is gone.
    func testLocalModeAndLongPressDelete() throws {
        try prepare()
        setMode(Self.local)
        XCTAssertTrue(element("rk.transmit").waitForNonExistence(timeout: 3), "step 11/13: rk.transmit must be hidden")
        XCTAssertFalse(element("rk.draft").exists, "step 11: no draft row in Local mode")

        type("abc")
        XCTAssertTrue(wait(3) { bodyText() == "abc" }, "step 11: body was '\(bodyText())'")
        type("defghijklmnopqrstuvw")
        let before = "abcdefghijklmnopqrstuvw"
        XCTAssertTrue(wait(3) { bodyText() == before }, "step 10: body was '\(bodyText())'")

        element("rk.backspace").press(forDuration: 1.0)
        Thread.sleep(forTimeInterval: 0.5)
        let after = bodyText()
        XCTAssertTrue(before.hasPrefix(after), "step 10: what is left must be a prefix, was '\(after)'")
        // A hold of 1.0 s deletes about six; at least three proves the key repeats, and it must not delete everything.
        XCTAssertLessThanOrEqual(after.count, before.count - 3, "step 10: the hold did not repeat")
        XCTAssertGreaterThan(after.count, 0, "step 10: the hold deleted everything")
        clearBody()

        // Steps 12: back to Remote brings the status and the transmit toggle back.
        setMode(Self.remote)
        XCTAssertTrue(element("rk.transmit").waitForExistence(timeout: 3), "step 12: rk.transmit must come back")
        XCTAssertTrue(element("rk.status").waitForExistence(timeout: 3), "step 12: rk.status must come back")
    }

    // MARK: Steps 14-21

    /// One draft built with cursor moves, an inserted line break and a delete, held for 4 s, then sent once.
    func testDraftEditing() throws {
        try prepare()
        let modeYBefore = element("rk.mode").frame.minY
        setTransmit(Self.draft)
        Thread.sleep(forTimeInterval: 1.0)
        let grew = modeYBefore - element("rk.mode").frame.minY
        XCTAssertTrue((30.0...42.0).contains(grew), "step 14: the keyboard should grow by 36 pt, grew \(grew)")
        expectDraft("", "step 14 empty draft")
        XCTAssertFalse(element("rk.send").isEnabled, "step 15: 傳送 must be grey on an empty draft")

        type("abcd")
        expectDraft("abcd", "step 15")
        tapID("rk.cursorLeft")
        tapID("rk.cursorLeft")
        tapID("rk.shift")
        tapKey("X")
        expectDraft("abXcd", "step 16")
        tapID("rk.cursorRight")
        tapID("rk.shift")
        tapKey("Y")
        expectDraft("abXcYd", "step 17")
        tapID("rk.backspace")
        expectDraft("abXcd", "step 19")

        // Step 18: cursor keys only move the draft cursor. Net movement is zero, so the cursor is after c again.
        for _ in 0..<3 { tapID("rk.cursorLeft") }
        for _ in 0..<3 { tapID("rk.cursorRight") }
        expectDraft("abXcd", "step 18")

        // Step 21: a line break inside the draft, at the cursor.
        type("ab")
        tapID("rk.return")
        type("cd")
        expectDraft("abXcab\ncdd", "step 21")

        mark("PAUSE_START")
        Thread.sleep(forTimeInterval: 4.0)
        expectDraft("abXcab\ncdd", "step 20 after the 4 s pause")
        XCTAssertEqual(bodyText(), "", "step 15: the note must stay empty")
        XCTAssertTrue(wait(10) { element("rk.send").isEnabled }, "step 20: 傳送 never turned on (is the Mac ready?)")

        mark("SEND")
        tapID("rk.send")
        expectDraft("", "step 20 after sending")
        XCTAssertFalse(element("rk.send").isEnabled, "step 20: 傳送 must be grey after sending")
        drain()
    }

    // MARK: Steps 22-25

    /// A draft stays in charge after switching to Instant, until it is sent; then live typing resumes.
    func testInstantWithDraftEditsDraft() throws {
        try prepare(transmit: Self.draft)
        type("xy")
        expectDraft("xy", "step 22 setup")
        setTransmit(Self.instant)
        expectDraft("xy", "step 23: the draft must stay after switching to Instant")
        tapID("rk.backspace")
        expectDraft("x", "step 22: delete edits the draft")
        tapKey("z")
        expectDraft("xz", "step 24: z goes to the draft")
        XCTAssertEqual(bodyText(), "", "step 24: the note must stay empty")
        XCTAssertTrue(wait(10) { element("rk.send").isEnabled }, "step 25: 傳送 never turned on (is the Mac ready?)")
        mark("SEND")
        tapID("rk.send")
        XCTAssertTrue(element("rk.draft").waitForNonExistence(timeout: 5), "step 25: the draft row must close after sending")
        tapKey("q")
        mark("Q_TYPED")
        XCTAssertFalse(element("rk.draft").exists, "step 25: q must go live, not to the draft")
        drain()
    }

    // MARK: Steps 26-27

    /// The script clears the Mac's focus after seeing the pulse letter `k`, and gives it back 15 s later.
    func testNotReadyGoesToDraft() throws {
        try prepare()
        // Pulse: the script sees this letter in TextEdit, wipes it and takes the focus away.
        tapKey("k")
        mark("PULSE_SENT")
        XCTAssertTrue(
            element("rk.draft").waitForExistence(timeout: 90),
            "step 26: the draft row never opened; the script did not take the Mac's focus away")
        mark("NOT_READY_SEEN")
        type("abc")
        mark("ABC_TYPED")
        expectDraft("abc", "step 26")
        XCTAssertFalse(element("rk.send").isEnabled, "step 26: 傳送 must be grey while the Mac is not ready")
        XCTAssertEqual(bodyText(), "", "step 26: the note must stay empty")

        XCTAssertTrue(wait(45) { element("rk.send").isEnabled }, "step 27: 傳送 never turned on after the Mac was ready again")
        mark("SEND_ENABLED")
        // Nothing may send by itself.
        Thread.sleep(forTimeInterval: 3.0)
        expectDraft("abc", "step 27: the draft must wait for 傳送")
        mark("SEND")
        tapID("rk.send")
        XCTAssertTrue(element("rk.draft").waitForNonExistence(timeout: 8), "step 27: the draft row must close after sending")
        drain()
    }

    // MARK: Steps 29-30

    /// The draft and its cursor survive a visit to Local mode. Nothing here may reach the Mac.
    func testModeSwitchKeepsDraft() throws {
        // The Mac is ready on purpose: a key that leaked to it instead of the draft would show up in TextEdit.
        try prepare(transmit: Self.draft)
        let withDraftY = element("rk.mode").frame.minY
        type("mn")
        tapID("rk.cursorLeft")
        expectDraft("mn", "step 29 setup")

        setMode(Self.local)
        XCTAssertTrue(element("rk.draft").waitForNonExistence(timeout: 3), "step 29: the draft row must close in Local mode")
        XCTAssertTrue(element("rk.transmit").waitForNonExistence(timeout: 3), "step 29: rk.transmit must close in Local mode")
        Thread.sleep(forTimeInterval: 1.0)
        let shrank = element("rk.mode").frame.minY - withDraftY
        XCTAssertTrue((30.0...42.0).contains(shrank), "step 29: the keyboard should shrink by 36 pt, shrank \(shrank)")
        tapKey("k")
        XCTAssertTrue(wait(3) { bodyText() == "k" }, "step 29: Local typing must reach the note, body was '\(bodyText())'")
        tapID("rk.backspace")
        XCTAssertTrue(wait(3) { bodyText().isEmpty }, "step 29: the note should be empty again")

        setMode(Self.remote)
        XCTAssertTrue(element("rk.draft").waitForExistence(timeout: 3), "step 30: the draft row must return")
        expectDraft("mn", "step 30")
        tapKey("p")
        expectDraft("mpn", "step 30: the cursor must still be after m")
        clearDraft()
    }

    // MARK: Steps 34-35

    /// The symbols page types into both targets; 中英 is disabled and does nothing.
    func testSymbolsAndPages() throws {
        try prepare()
        XCTAssertFalse(element("rk.zhEn").isEnabled, "step 35: 中英 must be disabled")
        tapID("rk.symbols")
        XCTAssertTrue(wait(3) { element("rk.symbols").label == Self.backToEnglishLabel }, "step 34: symbols page not shown")
        XCTAssertFalse(letterKey("q").exists, "step 34: letters must be hidden on the symbols page")
        tapKey("1")
        tapKey("@")
        XCTAssertFalse(element("rk.zhEn").isEnabled, "step 35: 中英 must stay disabled on the symbols page")
        tapID("rk.symbols")
        XCTAssertTrue(wait(3) { element("rk.symbols").label == Self.symbolsLabel }, "step 34: did not return to English")
        XCTAssertTrue(letterKey("q").waitForExistence(timeout: 3), "step 34: letters must be back")
        element("rk.zhEn").tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(letterKey("q").exists, "step 35: tapping 中英 must change nothing")
        XCTAssertEqual(bodyText(), "", "step 34: the note must stay empty in Remote mode")
        drain()

        // The same keys in Local mode.
        setMode(Self.local)
        tapID("rk.symbols")
        XCTAssertTrue(wait(3) { element("rk.symbols").label == Self.backToEnglishLabel }, "step 34 local: symbols page not shown")
        tapKey("1")
        tapKey("@")
        XCTAssertTrue(wait(3) { bodyText() == "1@" }, "step 34 local: body was '\(bodyText())'")
        tapID("rk.symbols")
        XCTAssertTrue(wait(3) { element("rk.symbols").label == Self.symbolsLabel }, "step 34 local: did not return to English")
        clearBody()
        setMode(Self.remote)
    }

    // MARK: Steps 1 and 38

    /// Read-only: identifiers, Taiwan Chinese labels and the AppGroup line. Spoken VoiceOver output stays manual.
    func testAccessibilityLabels() throws {
        try prepare(transmit: Self.draft, needMac: false)
        let labels: [(String, String)] = [
            ("rk.backspace", "刪除"), ("rk.space", "空白鍵"), ("rk.return", "換行"), ("rk.zhEn", "中英切換"),
            ("rk.symbols", "符號"), ("rk.shift", "大寫"), ("rk.cursorLeft", "游標左移"), ("rk.cursorRight", "游標右移"),
            ("rk.send", "傳送草稿"), ("rk.mode", "輸入位置"), ("rk.transmit", "傳送方式"), ("rk.draft", "草稿")
        ]
        for (identifier, expected) in labels {
            let found = element(identifier)
            XCTAssertTrue(found.waitForExistence(timeout: 3), "\(identifier) not found")
            XCTAssertEqual(found.label, expected, "label of \(identifier)")
        }
        for letter in ["q", "p", "a", "l", "z", "m"] {
            XCTAssertTrue(letterKey(letter).exists, "letter key \(letter) has no matching label")
        }
        let group = notes.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "AppGroup: OK")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 3), "step 1: the 'AppGroup: OK' line is missing")
    }

    // MARK: Steps 28 and 37

    /// 草稿 and 遠端 survive hiding the keyboard and a round trip through Safari.
    func testPersistence() throws {
        try prepare(needMac: false)
        setTransmit(Self.draft)
        hideKeyboard()
        try focusNoteBody()
        expectValue("rk.transmit", Self.draft, "step 28 after reopening")
        expectValue("rk.mode", Self.remote, "step 28 after reopening")

        XCUIApplication(bundleIdentifier: Self.safariID).activate()
        Thread.sleep(forTimeInterval: 2.0)
        notes.activate()
        try focusNoteBody()
        expectValue("rk.transmit", Self.draft, "step 28 after Safari")
        expectValue("rk.mode", Self.remote, "step 28 after Safari")

        setTransmit(Self.instant)
        hideKeyboard()
        try focusNoteBody()
        expectValue("rk.transmit", Self.instant, "step 37 after restoring Instant")
    }

    // MARK: Steps 32-33

    /// A web page with an email field and a number field. Typing the page address needs the system keyboard, so the
    /// case skips whenever Safari cannot be driven. It never taps a page that is not its own.
    func testFieldKinds() throws {
        let safari = XCUIApplication(bundleIdentifier: Self.safariID)
        safari.activate()
        guard let bar = addressBar(in: safari) else { throw XCTSkip("Safari: address bar not found") }
        bar.tap()
        let systemKeys = safari.keyboards.keys
        if !systemKeys.firstMatch.waitForExistence(timeout: 3) {
            let globe = safari.descendants(matching: .any).matching(identifier: "rk.globe").firstMatch
            guard globe.waitForExistence(timeout: 5) else { throw XCTSkip("Safari: no way to the system keyboard") }
            globe.tap()
            guard systemKeys.firstMatch.waitForExistence(timeout: 5) else { throw XCTSkip("Safari: system keyboard did not appear") }
        }
        guard let field = addressBar(in: safari) else { throw XCTSkip("Safari: address field not found") }
        field.typeText("data:text/html,<input type=email><input type=number>\n")

        let email = safari.webViews.textFields.element(boundBy: 0)
        let number = safari.webViews.textFields.element(boundBy: 1)
        guard email.waitForExistence(timeout: 10), number.exists else { throw XCTSkip("Safari: the test page did not load") }

        // Email field: the system keyboard is still current, so move on to the Remote Keyboard with its globe.
        email.tap()
        try switchToRemoteKeyboard(in: safari)
        let symbols = safari.descendants(matching: .any).matching(identifier: "rk.symbols").firstMatch
        XCTAssertTrue(symbols.waitForExistence(timeout: 5), "step 32: the keyboard did not appear in the email field")
        XCTAssertEqual(symbols.label, Self.symbolsLabel, "step 32: an email field must open the English page")
        dismissKeyboard(in: safari)

        // Number field: this keyboard is current now.
        number.tap()
        XCTAssertTrue(symbols.waitForExistence(timeout: 5), "step 33: the keyboard did not appear in the number field")
        XCTAssertEqual(symbols.label, Self.backToEnglishLabel, "step 33: a number field must open the symbols page")
        dismissKeyboard(in: safari)
    }

    // MARK: Step 31

    /// DEBUG hook: holding 空白 for 2 s fills the draft to 1,000 characters. One more letter must change nothing.
    /// The draft is never sent (1,000 characters must not reach the Mac); Notes is restarted to drop the controller.
    /// Deferred to T16 manual testing: the hook does not fire under an XCUITest press, so the case skips at once.
    /// Run it by name to try again; the body below is kept for that.
    func testDraftCap() throws {
        if Self.draftCapDeferred { throw XCTSkip("hook does not fire under XCUITest press; manual at T16") }
        try prepare(transmit: Self.draft, needMac: false)
        terminateNotesAfter = true
        expectDraft("", "step 31 start")
        element("rk.space").press(forDuration: 2.5)
        XCTAssertTrue(
            wait(10) { draftText()?.count == 1000 },
            "step 31: the draft holds \(draftText()?.count ?? -1) characters (is this a Debug build?)")
        tapKey("b")
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(draftText()?.count, 1000, "step 31: the draft must stay at 1,000")
        XCTAssertFalse(draftText()?.contains("b") ?? true, "step 31: the extra letter must not be inserted")
        XCTAssertTrue(
            wait(3) { element("rk.status").label.contains("1,000") },
            "step 31: no cap note, status line was '\(element("rk.status").label)'")
        XCTAssertEqual(bodyText(), "", "step 31: the note must stay empty")
    }

    // MARK: Preparing the keyboard

    /// A fresh note, the keyboard up, Remote mode, the wanted transmit mode, an empty draft and (optionally) a ready Mac.
    private func prepare(transmit: String = KeyboardT10UITests.instant, needMac: Bool = true) throws {
        try openFreshNote()
        try ensureKeyboard()
        setMode(Self.remote)
        if let leftover = draftText(), !leftover.isEmpty {
            guard leftover.count <= 60 else {
                terminateNotesAfter = true
                XCTFail("a leftover draft of \(leftover.count) characters is in the keyboard; run again after Notes restarts")
                return
            }
            clearDraft()
        }
        setTransmit(transmit)
        if needMac { waitForMacReady() }
    }

    private func openFreshNote() throws {
        notes.activate()
        var newNote = Self.firstMatch(
            in: notes, queries: [notes.buttons], identifiers: Self.newNoteIdentifiers, labels: Self.newNoteLabels, timeout: 4)
        if newNote == nil {
            hideKeyboard()
            newNote = Self.firstMatch(
                in: notes, queries: [notes.buttons], identifiers: Self.newNoteIdentifiers, labels: Self.newNoteLabels, timeout: 5)
        }
        guard let newNote else {
            throw XCTSkip("Notes: new-note button not found; start with Notes closed or on the notes list")
        }
        newNote.tap()
        let body = notes.textViews.firstMatch
        guard body.waitForExistence(timeout: 5) else { throw XCTSkip("Notes: the new note's body did not appear") }
        // Only an empty body is ever tapped, so an existing note can never be touched.
        guard Self.isEmpty(body) else {
            XCTFail("no safe tap target: the Notes body is not empty")
            return
        }
        body.tap()
    }

    /// Back into the test's own note after hiding the keyboard or switching apps. A note that is no longer there
    /// is replaced by a new one; a body that has text is never tapped.
    private func focusNoteBody() throws {
        notes.activate()
        let body = notes.textViews.firstMatch
        if body.waitForExistence(timeout: 3), Self.isEmpty(body) {
            body.tap()
        } else {
            try openFreshNote()
        }
        try ensureKeyboard()
    }

    private func ensureKeyboard() throws {
        let mode = element("rk.mode")
        var found = mode.waitForExistence(timeout: 10)
        var tries = 0
        while !found && tries < 6 {
            tries += 1
            guard let next = Self.nextKeyboardNames.map({ notes.keyboards.buttons[$0] }).first(where: { $0.exists }) else { break }
            next.tap()
            found = mode.waitForExistence(timeout: 2)
        }
        guard found else { throw XCTSkip("O6: third-party keyboard not reachable") }
    }

    private func waitForMacReady() {
        let ready = wait(20) {
            let status = element("rk.status")
            guard status.exists, (status.value as? String) == "connected" else { return false }
            let text = status.label
            return text.contains("Mac →") && !text.contains("無輸入欄位") && !text.contains("等待狀態")
        }
        XCTAssertTrue(
            ready, "the Mac is not ready (status '\(element("rk.status").label)'): Receiver armed, TextEdit focused, Mac paired?")
        XCTAssertTrue(
            wait(5) { draftText() == nil || draftText() == "" }, "the draft is not empty although the Mac is ready")
    }

    private func setMode(_ target: String) {
        let mode = element("rk.mode")
        XCTAssertTrue(mode.waitForExistence(timeout: 5), "rk.mode not found")
        if (mode.value as? String) != target { mode.tap() }
        XCTAssertTrue(wait(5) { value("rk.mode") == target }, "rk.mode did not become \(target), it is \(value("rk.mode") ?? "missing")")
    }

    private func setTransmit(_ target: String) {
        let transmit = element("rk.transmit")
        XCTAssertTrue(transmit.waitForExistence(timeout: 5), "rk.transmit not found (is the keyboard in Remote mode?)")
        if (transmit.value as? String) != target { transmit.tap() }
        XCTAssertTrue(
            wait(5) { value("rk.transmit") == target },
            "rk.transmit did not become \(target), it is \(value("rk.transmit") ?? "missing")")
    }

    /// Best effort and silent: Remote and Instant for whoever runs next. Local-mode leftovers are not cleaned here.
    private func restoreRemoteInstant() {
        let mode = element("rk.mode")
        guard mode.exists else { return }
        if (mode.value as? String) == Self.local { mode.tap() }
        let transmit = element("rk.transmit")
        if transmit.waitForExistence(timeout: 2), (transmit.value as? String) == Self.draft { transmit.tap() }
    }

    // MARK: Elements and keys

    private func element(_ identifier: String) -> XCUIElement {
        notes.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The value of an element that exists right now, otherwise `nil`.
    private func value(_ identifier: String) -> String? {
        let found = element(identifier)
        return found.exists ? found.value as? String : nil
    }

    private func letterKey(_ label: String) -> XCUIElement {
        notes.descendants(matching: .button).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func tapID(_ identifier: String) {
        let target = element(identifier)
        XCTAssertTrue(target.waitForExistence(timeout: 5), "\(identifier) not found")
        target.tap()
    }

    private func tapKey(_ label: String) {
        let key = letterKey(label)
        XCTAssertTrue(key.waitForExistence(timeout: 5), "key '\(label)' not found")
        key.tap()
    }

    private func type(_ text: String) {
        for character in text { tapKey(String(character)) }
    }

    private func expectValue(_ identifier: String, _ expected: String, _ context: String) {
        XCTAssertTrue(
            wait(3) { value(identifier) == expected },
            "\(context): \(identifier) is '\(value(identifier) ?? "missing")', expected '\(expected)'")
    }

    // MARK: Draft and body

    /// The draft text, `""` while it is empty, `nil` while the draft row is not showing.
    private func draftText() -> String? {
        guard let shown = value("rk.draft") else { return nil }
        return shown == Self.emptyDraft ? "" : shown
    }

    private func expectDraft(_ expected: String, _ context: String) {
        XCTAssertTrue(
            wait(3) { draftText() == expected },
            "\(context): draft is '\(draftText() ?? "no draft row")', expected '\(expected)'")
    }

    /// Moves to the end and deletes one by one. Only for short drafts.
    private func clearDraft() {
        guard let text = draftText(), !text.isEmpty else { return }
        for _ in 0..<text.count { tapID("rk.cursorRight") }
        for _ in 0..<text.count { tapID("rk.backspace") }
        XCTAssertTrue(wait(5) { draftText() == "" }, "the draft could not be cleared, it is '\(draftText() ?? "")'")
    }

    private func bodyText() -> String {
        let body = notes.textViews.firstMatch
        return body.exists ? (body.value as? String ?? "") : ""
    }

    /// Deletes Local-mode text so Notes discards the empty note. Never presses delete outside Local mode.
    private func clearBody() {
        XCTAssertEqual(value("rk.mode"), Self.local, "clearBody must only run in Local mode")
        var rounds = 0
        while !bodyText().isEmpty && rounds < 12 {
            rounds += 1
            element("rk.backspace").press(forDuration: 2.0)
        }
        XCTAssertTrue(bodyText().isEmpty, "the note could not be emptied: '\(bodyText())'")
    }

    // MARK: Waiting, marks, evidence

    @discardableResult
    private func wait(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return condition()
    }

    private func drain() {
        Thread.sleep(forTimeInterval: Self.drainSeconds)
    }

    /// A progress line, printed (the script may read it) and attached to the result.
    private func mark(_ event: String) {
        let line = "RKT10 \(name) \(event)"
        events.append(line)
        print(line)
    }

    private func attachEvidence() {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "end-state"
        shot.lifetime = .keepAlways
        add(shot)
        if !events.isEmpty {
            let log = XCTAttachment(string: events.joined(separator: "\n") + "\n")
            log.name = "t10-events.txt"
            log.lifetime = .keepAlways
            add(log)
        }
    }

    // MARK: Notes and Safari helpers

    private static func isEmpty(_ element: XCUIElement) -> Bool {
        (element.value as? String ?? "").isEmpty
    }

    private func hideKeyboard() {
        for dismiss in Self.dismissNames {
            let button = notes.buttons[dismiss].firstMatch
            if button.exists, button.isHittable {
                button.tap()
                break
            }
        }
        _ = element("rk.mode").waitForNonExistence(timeout: 2)
    }

    private func dismissKeyboard(in app: XCUIApplication) {
        for dismiss in Self.dismissNames {
            let button = app.buttons[dismiss].firstMatch
            if button.exists, button.isHittable {
                button.tap()
                break
            }
        }
        _ = app.descendants(matching: .any).matching(identifier: "rk.mode").firstMatch.waitForNonExistence(timeout: 2)
    }

    /// Steps from the system keyboard to this keyboard with the system globe, a few presses at most.
    private func switchToRemoteKeyboard(in app: XCUIApplication) throws {
        let mode = app.descendants(matching: .any).matching(identifier: "rk.mode").firstMatch
        var tries = 0
        while !mode.exists && tries < 5 {
            tries += 1
            guard let next = Self.nextKeyboardNames.map({ app.keyboards.buttons[$0] }).first(where: { $0.exists }) else {
                throw XCTSkip("Safari: the system keyboard's globe was not found")
            }
            next.tap()
            _ = mode.waitForExistence(timeout: 2)
        }
        guard mode.exists else { throw XCTSkip("Safari: could not switch to the Remote Keyboard") }
    }

    private func addressBar(in app: XCUIApplication) -> XCUIElement? {
        Self.firstMatch(
            in: app, queries: [app.textFields, app.buttons],
            identifiers: Self.addressIdentifiers, labels: Self.addressLabels, timeout: 5)
    }

    /// Polls until an element matches: every identifier first (in order), then every exact label, across `queries`.
    private static func firstMatch(
        in app: XCUIApplication, queries: [XCUIElementQuery], identifiers: [String], labels: [String], timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for id in identifiers {
                for query in queries {
                    let found = query.matching(identifier: id).firstMatch
                    if found.exists { return found }
                }
            }
            for label in labels {
                for query in queries {
                    let found = query.matching(NSPredicate(format: "label == %@", label)).firstMatch
                    if found.exists { return found }
                }
            }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return nil
    }
}
