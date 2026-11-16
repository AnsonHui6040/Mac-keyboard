import XCTest

/// Rotates the keyboard's current computer by tapping the host name cell, measures how long the last switch takes to reach
/// `connected`, then types a test token and Return to whichever computer is current.
///
/// Run on a physical iPhone with at least two computers paired. A tap on the name cell moves to the next paired computer,
/// so the rotation can pass through computers the run does not target (for example the Mac); nothing is typed until the
/// target is the current host and its link is `connected`.
///
/// Environment (`TEST_RUNNER_` prefix on the xcodebuild side):
/// - `RK_TARGET_HOST`: required; the host name the keyboard must show before it types.
/// - `RK_TOKEN`: required; ASCII lowercase letters and digits only. This is the only text the test types.
///
/// A target that is already current is rotated away and back anyway, so every run measures a real switch. Prints one line,
/// `RKROT host=<name> taps=<n> switch_ms=<n>`. The time runs from the moment the last tap returned to the first poll that
/// reads `connected`, so it carries the polling interval (about 0.2 s) and the accessibility query time.
///
/// Before every character key and Return the test reads the `rk.status` value, so a link that dropped while typing shows in
/// the run: `RKKEYS total=<n> notConnected=<n> firstNotConnectedAt=<index or -1>` (index counts from 0; page-switch taps are
/// not keys; no typed content is printed).
///
/// `testTypeBurst` does not rotate: the target must already be the current host (no tap on the name cell). Environment:
/// `RK_TARGET_HOST`, `RK_TOKEN_PREFIX` (lowercase a-z only) and `RK_COUNT` (1...200, default 50). It types `<prefix><i>` and
/// Return for i in 1...count and prints `RKBURST count=<n> keys=<n> notConnected=<n> start=<UTC ISO> end=<UTC ISO>`, plus
/// one `RKBURST_GAP token=<i>` for every token that had a key sent while the status was not `connected`.
@MainActor
final class HostRotationUITests: XCTestCase {
    private static let maxTaps = 6
    private static let nameChangeTimeout: TimeInterval = 5
    private static let connectTimeout: TimeInterval = 20
    private static let nameSeparator = "，"
    private static let maxDraftClearTaps = 400
    /// What `rk.draft` reports as its value while the draft is empty.
    private static let emptyDraftValue = "空白"
    private static let instantTitle = "即時"
    private static let draftTitle = "草稿"

    private let notes = XCUIApplication(bundleIdentifier: "com.apple.mobilenotes")

    /// Status readings taken before each key tap, since the last `resetKeyLog()`.
    private var keyTotal = 0
    private var keyNotConnected = 0
    private var firstNotConnectedAt = -1
    /// Whether any key of the token being typed had a status other than `connected`.
    private var tokenHadGap = false

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testRotateAndType() throws {
        let env = ProcessInfo.processInfo.environment
        guard let target = env["RK_TARGET_HOST"], !target.isEmpty else {
            XCTFail("RK_TARGET_HOST is not set (pass TEST_RUNNER_RK_TARGET_HOST)")
            return
        }
        guard let token = env["RK_TOKEN"], Self.isValidToken(token) else {
            XCTFail("RK_TOKEN must be set and use only a-z and 0-9 (pass TEST_RUNNER_RK_TOKEN)")
            return
        }

        try openNewNoteWithRemoteKeyboard()
        let mode = element("rk.mode")
        if (mode.value as? String) == "本機" { mode.tap() }
        XCTAssertTrue(wait(10) { currentHostName() != nil }, "no host name on the keyboard: is a computer paired and current?")
        try useInstantTransmit()
        try clearLeftoverTokensFromDraft()

        let (taps, switchMs) = try rotate(to: target)
        resetKeyLog()
        try typeToken(token)
        let draft = element("rk.draft")
        if draft.exists, "\(draft.value as? String ?? "")\(draft.label)".contains(token) {
            XCTFail("token stayed in the draft")
        }
        print("RKROT host=\(target) taps=\(taps) switch_ms=\(switchMs)")
        print(keyLogLine())
    }

    /// Types `<prefix><i>` and Return for every i in 1...count to the host that is already current, without rotating.
    func testTypeBurst() throws {
        let env = ProcessInfo.processInfo.environment
        guard let target = env["RK_TARGET_HOST"], !target.isEmpty else {
            XCTFail("RK_TARGET_HOST is not set (pass TEST_RUNNER_RK_TARGET_HOST)")
            return
        }
        guard let prefix = env["RK_TOKEN_PREFIX"], Self.isValidPrefix(prefix) else {
            XCTFail("RK_TOKEN_PREFIX must be set and use only a-z (pass TEST_RUNNER_RK_TOKEN_PREFIX)")
            return
        }
        guard let count = Self.burstCount(from: env["RK_COUNT"]) else {
            XCTFail("RK_COUNT must be a whole number from 1 to \(Self.maxBurstCount) (pass TEST_RUNNER_RK_COUNT)")
            return
        }

        try openNewNoteWithRemoteKeyboard()
        let mode = element("rk.mode")
        if (mode.value as? String) == "本機" { mode.tap() }
        XCTAssertTrue(wait(10) { currentHostName() != nil }, "no host name on the keyboard: is a computer paired and current?")
        guard currentHostName() == target else {
            XCTFail("[\(target)] is not the current host (shows [\(currentHostName() ?? "none")]); select it first, nothing was tapped or typed")
            return
        }
        try useInstantTransmit()
        try clearLeftoverTokensFromDraft(tokenPrefix: prefix)
        XCTAssertTrue(wait(Self.connectTimeout) { (element("rk.status").value as? String) == "connected" },
                      "[\(target)] not connected within \(Int(Self.connectTimeout)) s")
        if (element("rk.status").value as? String) != "connected" { return }

        resetKeyLog()
        var gaps: [Int] = []
        let start = Date()
        for i in 1...count {
            tokenHadGap = false
            try typeToken("\(prefix)\(i)", settle: false)
            if tokenHadGap { gaps.append(i) }
        }
        sleep(2)
        let end = Date()

        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        print("RKBURST count=\(count) keys=\(keyTotal) notConnected=\(keyNotConnected) start=\(stamp.string(from: start)) end=\(stamp.string(from: end))")
        for i in gaps { print("RKBURST_GAP token=\(i)") }
        print(keyLogLine())
        if !draftText().isEmpty { XCTFail("typed text stayed in the draft") }
    }

    // MARK: Key log

    private func resetKeyLog() {
        keyTotal = 0
        keyNotConnected = 0
        firstNotConnectedAt = -1
        tokenHadGap = false
    }

    /// Reads `rk.status` and records it; call right before a key tap.
    private func recordStatusBeforeKey() {
        let connected = (element("rk.status").value as? String) == "connected"
        if !connected {
            if firstNotConnectedAt < 0 { firstNotConnectedAt = keyTotal }
            keyNotConnected += 1
            tokenHadGap = true
        }
        keyTotal += 1
    }

    private func keyLogLine() -> String {
        "RKKEYS total=\(keyTotal) notConnected=\(keyNotConnected) firstNotConnectedAt=\(firstNotConnectedAt)"
    }

    // MARK: Transmit mode

    /// Typing only reaches the computer in 即時. When the toggle reads 草稿 it is switched to 即時 for this run and put back
    /// afterwards, also when the test fails. Nothing else on the keyboard is changed.
    private func useInstantTransmit() throws {
        let transmit = element("rk.transmit")
        XCTAssertTrue(transmit.waitForExistence(timeout: 5), "rk.transmit not found (is the keyboard in Remote mode?)")
        guard (transmit.value as? String) == Self.draftTitle else { return }
        addTeardownBlock { [self] in
            let toggle = element("rk.transmit")
            if toggle.exists, (toggle.value as? String) == Self.instantTitle { toggle.tap() }
        }
        transmit.tap()
        XCTAssertTrue(wait(5) { (element("rk.transmit").value as? String) == Self.instantTitle }, "rk.transmit did not become 即時")
    }

    // MARK: Draft

    /// Typed keys go to the draft whenever it is not empty, even in 即時, so tokens left there by an earlier run are removed
    /// first. Only a draft made of wl11 tokens (or, in the burst test, tokens of its own prefix) and white space is touched; anything else fails the test untouched.
    private func clearLeftoverTokensFromDraft(tokenPrefix: String? = nil) throws {
        var text = draftText()
        if text.isEmpty { return }
        guard Self.isOnlyTokens(text, prefix: tokenPrefix) else {
            XCTFail("draft holds other text; clear it by hand")
            throw RotationError.draftNotEmpty
        }
        var taps = 0
        // The draft is read before every tap: a Backspace on an empty draft would be sent to the computer.
        while !text.isEmpty, taps < Self.maxDraftClearTaps {
            element("rk.backspace").tap()
            taps += 1
            text = draftText()
        }
        if !text.isEmpty {
            XCTFail("draft still not empty after \(taps) Backspace taps")
            throw RotationError.draftNotEmpty
        }
    }

    /// The draft's text; empty when there is no draft row or it reports the empty marker.
    private func draftText() -> String {
        let draft = element("rk.draft")
        guard draft.exists else { return "" }
        let value = draft.value as? String ?? ""
        return value == Self.emptyDraftValue ? "" : value
    }

    // MARK: Pure logic

    /// Whether the text is made of `wl11r<digits>` tokens, or `<prefix><digits>` tokens when a prefix is given, and white
    /// space only (at least one token).
    static func isOnlyTokens(_ text: String, prefix: String? = nil) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        return !words.isEmpty && words.allSatisfy { word in
            isToken(word, prefix: "wl11r") || (prefix.map { isValidPrefix($0) && isToken(word, prefix: $0) } ?? false)
        }
    }

    private static func isToken(_ word: Substring, prefix: String) -> Bool {
        word.hasPrefix(prefix) && word.count > prefix.count && word.dropFirst(prefix.count).allSatisfy { ("0"..."9").contains($0) }
    }

    static let maxBurstCount = 200

    /// `RK_COUNT`: nil unless a whole number in 1...maxBurstCount; unset means 50.
    static func burstCount(from value: String?) -> Int? {
        guard let value, !value.isEmpty else { return 50 }
        guard value.allSatisfy({ ("0"..."9").contains($0) }), let n = Int(value), (1...maxBurstCount).contains(n) else { return nil }
        return n
    }

    static func isValidPrefix(_ prefix: String) -> Bool {
        !prefix.isEmpty && prefix.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
    }

    static func isValidToken(_ token: String) -> Bool {
        !token.isEmpty && token.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    /// The host name out of a status cell label of the form `<name>，<status>`; the whole label when it has no separator.
    static func hostName(fromStatusLabel label: String) -> String? {
        let name = label.components(separatedBy: nameSeparator).first?.trimmingCharacters(in: .whitespaces) ?? ""
        return name.isEmpty ? nil : name
    }

    // MARK: Rotation

    /// Taps until the target shows (at least once), then waits for `connected`. Returns the tap count and the switch time.
    private func rotate(to target: String) throws -> (taps: Int, switchMs: Int) {
        var taps = 0
        var lastTapEnd = Date()
        repeat {
            guard taps < Self.maxTaps else {
                XCTFail("[\(target)] did not come up within \(Self.maxTaps) taps; last seen [\(currentHostName() ?? "none")]")
                throw RotationError.targetNotReached
            }
            let before = currentHostName()
            element("rk.status").tap()
            lastTapEnd = Date()
            taps += 1
            guard wait(Self.nameChangeTimeout, { currentHostName() != before }) else {
                XCTFail("tap \(taps) did not change the host (still [\(before ?? "none")]): only one computer paired?")
                throw RotationError.targetNotReached
            }
        } while currentHostName() != target

        let connected = wait(Self.connectTimeout) {
            currentHostName() == target && (element("rk.status").value as? String) == "connected"
        }
        let switchMs = Int(Date().timeIntervalSince(lastTapEnd) * 1000)
        XCTAssertTrue(connected, "[\(target)] not connected within \(Int(Self.connectTimeout)) s (is the receiver running and in range?)")
        if !connected { throw RotationError.notConnected }
        return (taps, switchMs)
    }

    /// `rk.hostName` when the label is exposed to accessibility, otherwise the name part of the `rk.status` label.
    private func currentHostName() -> String? {
        let name = element("rk.hostName")
        if name.exists, !name.label.isEmpty { return name.label }
        let status = element("rk.status")
        guard status.exists else { return nil }
        return Self.hostName(fromStatusLabel: status.label)
    }

    // MARK: Typing

    /// Digits live on the symbols page, letters on the English page; the page is switched only when the next character needs it.
    private func typeToken(_ token: String, settle: Bool = true) throws {
        if !key("a").exists { element("rk.zhEn").tap() }
        for character in token {
            let wantsSymbols = character.isNumber
            let onSymbols = element("rk.symbols").label == "返回英文字母"
            if wantsSymbols != onSymbols { try togglePage(toSymbols: wantsSymbols) }
            tapKey(String(character))
        }
        if element("rk.symbols").label == "返回英文字母" { try togglePage(toSymbols: false) }
        recordStatusBeforeKey()
        element("rk.return").tap()
        if settle { sleep(2) }
    }

    private func togglePage(toSymbols: Bool) throws {
        element("rk.symbols").tap()
        let expected = toSymbols ? "返回英文字母" : "符號"
        XCTAssertTrue(wait(3) { element("rk.symbols").label == expected }, "page did not switch")
    }

    // MARK: Notes and keyboard

    private func openNewNoteWithRemoteKeyboard() throws {
        notes.activate()
        let newNote = notes.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", "新增備忘錄", "Compose")).firstMatch
        if newNote.waitForExistence(timeout: 5) { newNote.tap() }
        let body = notes.textViews.firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 5), "no note body")
        if (body.value as? String ?? "").isEmpty { body.tap() }
        if element("rk.mode").waitForExistence(timeout: 3) { return }
        let globe = notes.buttons.matching(NSPredicate(format: "label == %@", "下一個鍵盤")).firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 5), "no globe key")
        globe.press(forDuration: 1.2)
        let item = notes.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Remote Keyboard")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), "Remote Keyboard not in the globe menu")
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(element("rk.mode").waitForExistence(timeout: 10), "Remote Keyboard did not appear")
    }

    private func element(_ id: String) -> XCUIElement { notes.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func key(_ label: String) -> XCUIElement {
        notes.descendants(matching: .button).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func tapKey(_ label: String) {
        let k = key(label)
        XCTAssertTrue(k.waitForExistence(timeout: 5), "key \(label)")
        recordStatusBeforeKey()
        k.tap()
    }

    private func wait(_ seconds: Double, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; usleep(200_000) }
        return condition()
    }

    private enum RotationError: Error { case targetNotReached, notConnected, draftNotEmpty }
}
