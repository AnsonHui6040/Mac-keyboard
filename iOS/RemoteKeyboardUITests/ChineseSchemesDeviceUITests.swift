import XCTest

/// Stress tests of the five keyed Chinese methods (速成, 倉頡, 注音, 拼音, 粵拼) typed through the real keyboard, meant for
/// the simulator first and then a device, one method at a time (`-only-testing:.../test<Case>_<scheme>`).
///
/// Every observation is a plain line starting with `RKSTRESS ` (printed and attached as `rkstress-<test>.txt`), so
/// `grep RKSTRESS` of the xcodebuild output is enough. `RKSTRESS_SEED` (pass it as `TEST_RUNNER_RKSTRESS_SEED`) seeds the
/// random keys; the default is 20261121 and the seed is printed. The product is never touched: the tests only tap keys.
///
/// Cases: A `testRandomKeys_*` (200 random key taps with commits and clears), B `testPickCandidate1to10_*` (candidates 1
/// to 10 one by one), C `testEdgeCases_*` (seven edge cases), D `testSchemeCycle` (all five methods switched in turn).
@MainActor
final class ChineseSchemesDeviceUITests: XCTestCase {
    private static let nextKeyboardNames = ["Next keyboard", "下一個鍵盤", "地球", "Globe", "下一個輸入法"]
    private static let localModeValue = "本機"
    private static let placeholder = "在這裡輸入"
    private static let defaultSeed: UInt64 = 20_261_121

    // MARK: Schemes

    /// One method under test. `cap` is the code length the tests stop at; `realCap` is `RimeSchemeConfig.maxCodeLength`.
    struct Scheme {
        let raw: String
        let keys: [String]
        let cap: Int
        let realCap: Int
        /// A code with at least one candidate; its first candidate is what space commits.
        let primary: [String]
        /// The code of case B, the first candidates of the dictionary for it (order by the dictionary), the number the
        /// dictionary has for it (B needs min(10, this) to be on the bar).
        let pickCode: [String]
        let pickExpected: [String]
        let pickDictionaryCount: Int
        /// Three keys for the backspace case (quick keeps two, its cap).
        let backspaceCode: [String]
        /// One code and the character it gives first, for the scheme cycle.
        let cycleCode: [String]
        let cycleExpected: String

        static let letters = "abcdefghijklmnopqrstuvwxyz".map { String($0) }
        static let bopomofo = "1234567890-qwertyuiopasdfghjkl;zxcvbnm,./".map { String($0) }

        static let quick = Scheme(
            raw: "quick", keys: letters, cap: 2, realCap: 2, primary: ["h", "u"],
            pickCode: ["a", "a"], pickExpected: ["昌", "晶", "暑", "間", "暗", "曙", "昍", "暙", "闍", "閶"],
            pickDictionaryCount: 15, backspaceCode: ["h", "u"], cycleCode: ["h", "u"], cycleExpected: "毛")
        static let cangjie = Scheme(
            raw: "cangjie", keys: letters, cap: 5, realCap: 5, primary: ["a", "b"],
            pickCode: ["t", "h", "o", "o"], pickExpected: ["蓏", "蓗", "蓰", "蓯"], pickDictionaryCount: 4,
            backspaceCode: ["h", "q", "i"], cycleCode: ["h", "q", "i"], cycleExpected: "我")
        static let zhuyin = Scheme(
            raw: "zhuyin", keys: bopomofo, cap: 6, realCap: 60, primary: ["g", "4"],
            pickCode: ["g", "4"], pickExpected: ["是", "事", "市", "式", "示", "視", "世", "士", "識", "試"],
            pickDictionaryCount: 111, backspaceCode: ["x", "u", "3"], cycleCode: ["g", "4"], cycleExpected: "是")
        static let pinyin = Scheme(
            raw: "pinyin", keys: letters, cap: 6, realCap: 60, primary: ["n", "i"],
            pickCode: ["s", "h", "i"], pickExpected: ["是", "時", "十", "事", "實", "市", "使", "式", "什", "師"],
            pickDictionaryCount: 215, backspaceCode: ["s", "h", "i"], cycleCode: ["n", "i"], cycleExpected: "你")
        static let jyutping = Scheme(
            raw: "jyutping", keys: letters, cap: 6, realCap: 60, primary: ["s", "i"],
            pickCode: ["s", "i"], pickExpected: ["時", "事", "是", "死", "四", "思", "試", "士", "使", "司"],
            pickDictionaryCount: 132, backspaceCode: ["n", "e", "i"], cycleCode: ["s", "i"], cycleExpected: "時")

        static let all = [quick, cangjie, zhuyin, pinyin, jyutping]
    }

    private struct Fatal: Error, CustomStringConvertible {
        let description: String
    }

    /// What the candidate strip shows: the input code and the candidates in order.
    private struct State: Equatable {
        var composing = ""
        var candidates: [String] = []
        var isEmpty: Bool { composing.isEmpty && candidates.isEmpty }
    }

    private struct Reading {
        var state = State()
        var alive = false
        var failed = false
        var frames: [String: CGRect] = [:]
    }

    private struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    private var app: XCUIApplication!
    private var lines: [String] = []
    private var anomalyShots = 0

    override func setUp() async throws {
        continueAfterFailure = true
        lines = []
        anomalyShots = 0
    }

    // MARK: Case A: random keys

    func testRandomKeys_quick() throws { try randomKeys(.quick) }
    func testRandomKeys_cangjie() throws { try randomKeys(.cangjie) }
    func testRandomKeys_zhuyin() throws { try randomKeys(.zhuyin) }
    func testRandomKeys_pinyin() throws { try randomKeys(.pinyin) }
    func testRandomKeys_jyutping() throws { try randomKeys(.jyutping) }

    private func randomKeys(_ scheme: Scheme) throws {
        try begin(scheme, name: "A-\(scheme.raw)")
        let seed = Self.seed()
        emit("A-SEED scheme=\(scheme.raw) seed=\(seed) cap=\(scheme.cap) real_cap=\(scheme.realCap)")
        var rng = SplitMix64(state: seed)
        let field = testField()
        let frames = try screenFrames()
        var code: [String] = []
        var current = read().state
        XCTAssertTrue(current.isEmpty, "the strip was not empty before the first key")
        var waits: [Int] = []
        var zeroCandidatesWithCode = 0
        var commits = 0
        var clears = 0
        var finishes = 0
        var unchanged = 0

        for i in 1...200 {
            let key = scheme.keys[Int.random(in: 0..<scheme.keys.count, using: &rng)]
            emit("A-KEY scheme=\(scheme.raw) i=\(i) key=\(key)")
            fastTap("rk.ime.\(key)", frames: frames)
            code.append(key)
            let settled = settle(from: current)
            let reading = settled.reading
            waits.append(settled.ms)
            if !settled.changed { unchanged += 1 }
            let state = reading.state
            if state.candidates.isEmpty { zeroCandidatesWithCode += 1 }
            emit(
                "A scheme=\(scheme.raw) i=\(i) code=\(code.joined()) preedit_len=\(state.composing.count) "
                    + "cands=\(state.candidates.count) first=\(state.candidates.first ?? "") wait_ms=\(settled.ms)"
                    + (settled.changed ? "" : " unchanged=1"))
            try checkAlive(reading, scheme, "after key \(i)")
            XCTAssertLessThanOrEqual(settled.ms, 3000, "key \(i) took more than 3 s to settle")
            checkCandidates(state, scheme, "after key \(i)")
            current = state

            let finish = code.count >= scheme.cap || Int.random(in: 0..<6, using: &rng) == 0
            guard finish else { continue }
            let before = fieldText(field)
            let useSpace = finishes % 2 == 0
            finishes += 1
            var done: (reading: Reading, ms: Int, changed: Bool)
            var presses = 1
            if useSpace {
                fastTap("rk.space", frames: frames)
                done = settle(from: current)
                // A sentence scheme (注音, 拼音, 粵拼) turns the first candidate into a partial pick when the code holds
                // more syllables than that candidate covers: nothing is committed yet and the rest stays composing.
                // Space again until the strip is empty (a code nothing matches is cleared by the first space).
                while !done.reading.state.isEmpty, presses < code.count + 3 {
                    presses += 1
                    let previous = done.reading.state
                    fastTap("rk.space", frames: frames)
                    done = settle(from: previous)
                }
            } else {
                fastTap("rk.return", frames: frames)
                done = settle(from: current)
            }
            try checkAlive(done.reading, scheme, "after \(useSpace ? "space" : "return") at key \(i)")
            let after = waitForField(field, notEqualTo: before, timeout: useSpace && !current.candidates.isEmpty ? 3 : 0.3)
            if useSpace, let first = current.candidates.first {
                commits += 1
                XCTAssertGreaterThan(after.count, before.count, "space after key \(i) did not add text")
                if presses > 1 { emit("A-NOTE scheme=\(scheme.raw) i=\(i) space_presses=\(presses) partial_pick=1") }
                if after != before + first, presses == 1 { emit("A-NOTE scheme=\(scheme.raw) i=\(i) space_commit_differs_from_first=1") }
            } else {
                clears += 1
                XCTAssertEqual(after, before, "\(useSpace ? "space with no candidate" : "return") after key \(i) changed the field")
            }
            XCTAssertTrue(done.reading.state.isEmpty, "the strip was not empty after finishing at key \(i)")
            if !done.reading.state.isEmpty { shot("A-\(scheme.raw)-not-empty-\(i)") }
            code = []
            current = done.reading.state
        }
        let sorted = waits.sorted()
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        emit(
            "A-SUM scheme=\(scheme.raw) taps=200 zero_cand_with_code=\(zeroCandidatesWithCode) "
                + "max_wait_ms=\(sorted.last ?? 0) p95_wait_ms=\(p95) commits=\(commits) clears=\(clears) unchanged=\(unchanged)")
    }

    // MARK: Case B: candidates 1 to 10

    func testPickCandidate1to10_quick() throws { try pickCandidates(.quick) }
    func testPickCandidate1to10_cangjie() throws { try pickCandidates(.cangjie) }
    func testPickCandidate1to10_zhuyin() throws { try pickCandidates(.zhuyin) }
    func testPickCandidate1to10_pinyin() throws { try pickCandidates(.pinyin) }
    func testPickCandidate1to10_jyutping() throws { try pickCandidates(.jyutping) }

    private func pickCandidates(_ scheme: Scheme) throws {
        try begin(scheme, name: "B-\(scheme.raw)")
        let field = testField()
        let wanted = min(10, scheme.pickDictionaryCount)
        emit("B-CODE scheme=\(scheme.raw) code=\(scheme.pickCode.joined()) dictionary_candidates=\(scheme.pickDictionaryCount) tested=\(wanted)")
        var firstTen: [String] = []
        for k in 1...10 {
            try clearCode(read().state)
            try clearField(field)
            try tapKeys(scheme.pickCode)
            let typed = settle(from: State(), quiet: 0.4)
            let list = typed.reading.state.candidates
            if k == 1 {
                firstTen = Array(list.prefix(10))
                XCTAssertGreaterThanOrEqual(list.count, wanted, "\(scheme.raw): the strip shows \(list.count) candidates, the dictionary has \(scheme.pickDictionaryCount)")
                emit("B-COUNT scheme=\(scheme.raw) shown=\(list.count)")
            }
            guard list.count >= k else {
                emit("B scheme=\(scheme.raw) k=\(k) ok=skip note=only_\(list.count)_candidates")
                try tap("rk.return")
                _ = settle(from: typed.reading.state)
                continue
            }
            let expected = list[k - 1]
            var tapped = try tapCandidate(index: k - 1)
            var text = waitForField(field, equalTo: expected, timeout: 2)
            var retries = 0
            while text != expected, retries < 2, !read().state.isEmpty {
                retries += 1
                tapped = try tapCandidate(index: k - 1)
                text = waitForField(field, equalTo: expected, timeout: 2)
            }
            let after = settle(from: typed.reading.state)
            let cleared = after.reading.state.isEmpty
            let ok = tapped && text == expected && cleared
            emit("B scheme=\(scheme.raw) k=\(k) ok=\(ok ? 1 : 0) scrolled=\(tapped ? 1 : 0) field_matches=\(text == expected ? 1 : 0) strip_cleared=\(cleared ? 1 : 0) retries=\(retries)")
            XCTAssertEqual(text, expected, "\(scheme.raw) candidate \(k)")
            XCTAssertTrue(cleared, "\(scheme.raw) candidate \(k): the strip kept candidates after the pick")
            if !ok { shot("B-\(scheme.raw)-k\(k)") }
        }
        var match = 0
        for (index, text) in scheme.pickExpected.enumerated() where firstTen.indices.contains(index) && firstTen[index] == text {
            match += 1
        }
        emit("B-ORDER scheme=\(scheme.raw) match=\(match)/\(min(10, scheme.pickExpected.count)) got=\(firstTen.joined(separator: ",")) dictionary=\(scheme.pickExpected.joined(separator: ","))")
    }

    // MARK: Case C: edge cases

    func testEdgeCases_quick() throws { try edgeCases(.quick) }
    func testEdgeCases_cangjie() throws { try edgeCases(.cangjie) }
    func testEdgeCases_zhuyin() throws { try edgeCases(.zhuyin) }
    func testEdgeCases_pinyin() throws { try edgeCases(.pinyin) }
    func testEdgeCases_jyutping() throws { try edgeCases(.jyutping) }

    private func edgeCases(_ scheme: Scheme) throws {
        try begin(scheme, name: "C-\(scheme.raw)")
        let field = testField()
        var rng = SplitMix64(state: Self.seed() &+ 7)

        // 1. Return clears the code.
        do {
            let base = fieldText(field)
            try tapKeys(scheme.primary)
            let typed = settle(from: State(), quiet: 0.4)
            try tap("rk.return")
            let done = settle(from: typed.reading.state)
            let text = fieldText(field)
            let ok = !typed.reading.state.candidates.isEmpty && text == base && done.reading.state.isEmpty
            item(1, scheme, ok, "had \(typed.reading.state.candidates.count) candidates, field unchanged=\(text == base), strip empty=\(done.reading.state.isEmpty)")
        }

        // 2. Backspace: type up to three keys, remove them, then the next backspace deletes a field character.
        do {
            try tapKeys(scheme.primary)
            try tap("rk.space")
            let committed = waitForField(field, notEqualTo: "", timeout: 4)
            let base = fieldText(field)
            let typedKeys = Array(scheme.backspaceCode.prefix(min(3, scheme.cap)))
            try tapKeys(typedKeys)
            var state = settle(from: State()).reading.state
            for _ in typedKeys {
                try tap("rk.ime.backspace")
                state = settle(from: state, timeout: 0.8).reading.state
            }
            let clean = state.isEmpty
            let unchanged = fieldText(field) == base
            try tap("rk.ime.backspace")
            let after = waitForField(field, notEqualTo: base, timeout: 3)
            let deleted = after == String(base.dropLast())
            item(2, scheme, !committed.isEmpty && clean && unchanged && deleted,
                 "typed \(typedKeys.count) keys, strip empty after backspaces=\(clean), field unchanged=\(unchanged), next backspace deleted one char=\(deleted)")
        }

        // 3. Space commits the first candidate.
        do {
            try clearField(field)
            try tapKeys(scheme.primary)
            let typed = settle(from: State(), quiet: 0.4)
            let first = typed.reading.state.candidates.first ?? ""
            try tap("rk.space")
            let text = waitForField(field, equalTo: first, timeout: 4)
            item(3, scheme, !first.isEmpty && text == first, "first candidate committed=\(text == first)")
        }

        // 4. A code far beyond the cap: the keyboard must survive.
        do {
            try clearField(field)
            let count = scheme.cap + 5
            for _ in 0..<count { try tap("rk.ime.\(scheme.keys[Int.random(in: 0..<scheme.keys.count, using: &rng)])") }
            let settled = settle(from: State(), timeout: 2)
            let state = settled.reading.state
            let withinCap = state.composing.count <= max(scheme.cap, scheme.realCap)
            item(4, scheme, settled.reading.alive && withinCap,
                 "\(count) keys, alive=\(settled.reading.alive), preedit_len=\(state.composing.count), candidates=\(state.candidates.count)")
            try clearCode(state)
        }
        if scheme.realCap > scheme.cap {
            let frames = try screenFrames()
            let count = scheme.realCap + 5
            for _ in 0..<count { fastTap("rk.ime.\(scheme.keys[Int.random(in: 0..<scheme.keys.count, using: &rng)])", frames: frames) }
            let settled = settle(from: State(), timeout: 2)
            item("4b", scheme, settled.reading.alive,
                 "\(count) keys fast, alive=\(settled.reading.alive), preedit_len=\(settled.reading.state.composing.count), candidates=\(settled.reading.state.candidates.count)")
            try clearCode(settled.reading.state)
        }

        // 5. Fifty quick taps without waiting; after two seconds the strip must match the same keys typed slowly.
        do {
            try clearField(field)
            let frames = try screenFrames()
            var typed: [String] = []
            for _ in 0..<50 { typed.append(scheme.keys[Int.random(in: 0..<scheme.keys.count, using: &rng)]) }
            let start = Date()
            for key in typed { fastTap("rk.ime.\(key)", frames: frames) }
            let tapped = Date().timeIntervalSince(start)
            var samples: [(Double, State)] = []
            let waitStart = Date()
            while Date().timeIntervalSince(waitStart) < 2 {
                samples.append((Date().timeIntervalSince(waitStart), read().state))
                Thread.sleep(forTimeInterval: 0.05)
            }
            let final = read()
            var stableAt = 0.0
            for (time, state) in samples.reversed() { if state == final.state { stableAt = time } else { break } }
            let kept = Array(typed.prefix(scheme.realCap))
            try clearCode(final.state)
            for key in kept {
                fastTap("rk.ime.\(key)", frames: frames)
                Thread.sleep(forTimeInterval: 0.15)
            }
            Thread.sleep(forTimeInterval: 2)
            let again = read()
            let same = again.state == final.state
            item(5, scheme, final.alive && same,
                 "50 taps in \(Int(tapped * 1000)) ms, stable \(Int(stableAt * 1000)) ms after the last tap, preedit_len=\(final.state.composing.count), candidates=\(final.state.candidates.count), same as slow typing=\(same)")
            try clearCode(again.state)
        }

        // 6. The 中英 key while a code is composing.
        do {
            try clearField(field)
            let base = fieldText(field)
            try tapKeys(scheme.primary)
            let typed = settle(from: State(), quiet: 0.4)
            try tap("rk.zhEn")
            Thread.sleep(forTimeInterval: 0.6)
            let onEnglish = fieldText(field)
            try tap("rk.zhEn")
            guard element("rk.ime.backspace").waitForExistence(timeout: 8) else { throw Fatal(description: "the Chinese page did not come back") }
            Thread.sleep(forTimeInterval: 0.4)
            let back = read().state
            let what: String
            if onEnglish != base { what = "committed" } else if !back.isEmpty { what = "kept" } else { what = "cleared" }
            let consistent = back.composing.isEmpty == back.candidates.isEmpty
            XCTAssertTrue(consistent, "\(scheme.raw): the strip shows candidates without a code (or the reverse) after the 中英 round trip")
            item(6, scheme, back.candidates.isEmpty,
                 "code was \(what) (had \(typed.reading.state.candidates.count) candidates), candidates after return=\(back.candidates.count), consistent=\(consistent)")
            try clearCode(back)
        }

        // 7. Thirty commits in a row.
        do {
            try clearField(field)
            let base = fieldText(field)
            var expected = ""
            var firsts = 0
            var state = State()
            for _ in 0..<30 {
                try tapKeys(scheme.primary)
                let typed = settle(from: state, quiet: 0.4)
                let first = typed.reading.state.candidates.first ?? ""
                try tap("rk.space")
                let done = settle(from: typed.reading.state)
                state = done.reading.state
                expected += first
                if !first.isEmpty { firsts += 1 }
            }
            let text = waitForField(field, equalTo: base + expected, timeout: 5)
            item(7, scheme, firsts == 30 && text == base + expected && text.count == base.count + expected.count,
                 "30 commits, field characters=\(text.count), expected=\(base.count + expected.count), with a first candidate=\(firsts)")
        }
    }

    // MARK: Case D: all five methods in turn

    func testSchemeCycle() throws {
        addTeardownBlock { @MainActor [weak self] in self?.attachLog("D") }
        launch()
        var results: [(String, String, String)] = []
        let order = Scheme.all + Scheme.all.reversed()
        for (pass, scheme) in order.enumerated() {
            if pass > 0 { app.navigationBars.buttons.firstMatch.tap() }
            try chooseMethod(scheme.raw)
            try openKeyboardOnChinesePage()
            let field = testField()
            try tapKeys(scheme.cycleCode)
            let typed = settle(from: State(), quiet: 0.4)
            let first = typed.reading.state.candidates.first ?? ""
            try tap("rk.space")
            let text = waitForField(field, equalTo: scheme.cycleExpected, timeout: 5)
            let ok = text == scheme.cycleExpected && first == scheme.cycleExpected
            emit("D scheme=\(scheme.raw) pass=\(pass + 1) code=\(scheme.cycleCode.joined()) first=\(first) field=\(text) expected=\(scheme.cycleExpected) ok=\(ok ? 1 : 0)")
            XCTAssertEqual(text, scheme.cycleExpected, "pass \(pass + 1) \(scheme.raw)")
            results.append((scheme.raw, text, scheme.cycleExpected))
        }
        let expectedOrder = order.map(\.cycleExpected)
        XCTAssertEqual(results.map { $0.1 }, expectedOrder, "the characters came out in the wrong order")
        let distinct = Set(Scheme.all.map(\.cycleExpected)).count
        emit("D-SUM passes=\(results.count) distinct_expected=\(distinct) all_ok=\(results.allSatisfy { $0.1 == $0.2 } ? 1 : 0)")
    }




    // MARK: Regression: heavy candidate updates must not hang the keyboard

    /// Zhuyin 't' then 'm' (185 candidates, then another set) used to leave the extension's main thread spinning in
    /// Auto Layout (`NSISEngine optimize`) for good, because every candidate button carried width constraints inside
    /// the keyboard's own layout engine. Every key is followed by a timed screen read: a hung extension makes the
    /// read fail or exceed the limit. The code is not one character per key: the display puts a separator where a new
    /// syllable starts, so the lengths below are what the first GREEN run showed (tm: 1, 3; m4n: 1, 2, 4; after the
    /// delete key: 1 and 2).
    func testNoHang_heavyCandidateUpdates_zhuyin() throws {
        try begin(.zhuyin, name: "nohang")
        let frames = try screenFrames()
        let cases: [(keys: [String], codeLengths: [Int], afterBackspace: Int)] = [
            (["t", "m"], [1, 3], 1),
            (["m", "4", "n"], [1, 2, 4], 2)
        ]
        for (seqIndex, sequence) in cases.enumerated() {
            for (i, key) in sequence.keys.enumerated() {
                fastTap("rk.ime.\(key)", frames: frames)
                let start = Date()
                let reading = read()
                let ms = Int(Date().timeIntervalSince(start) * 1000)
                emit("H scheme=zhuyin seq=\(seqIndex) i=\(i + 1) key=\(key) code_len=\(reading.state.composing.count) cands=\(reading.state.candidates.count) read_ms=\(ms)")
                XCTAssertFalse(reading.failed, "seq \(seqIndex) key \(i + 1): the screen could not be read (keyboard hung)")
                XCTAssertTrue(reading.alive, "seq \(seqIndex) key \(i + 1): the delete key is gone")
                XCTAssertEqual(reading.state.composing.count, sequence.codeLengths[i], "seq \(seqIndex) key \(i + 1): code length")
                if i == 0 { XCTAssertGreaterThanOrEqual(reading.state.candidates.count, 150, "seq \(seqIndex): the heavy candidate list was not produced") }
                XCTAssertLessThan(ms, 5000, "seq \(seqIndex) key \(i + 1): the read took \(ms) ms")
            }
            fastTap("rk.ime.backspace", frames: frames)
            let after = read()
            emit("H scheme=zhuyin seq=\(seqIndex) backspace code_len=\(after.state.composing.count) cands=\(after.state.candidates.count)")
            XCTAssertFalse(after.failed, "seq \(seqIndex): the screen could not be read after the delete key")
            XCTAssertEqual(after.state.composing.count, sequence.afterBackspace, "seq \(seqIndex): the delete key did not remove one symbol")
            try clearCode(after.state)
        }
    }

    // MARK: Reporting

    private static func seed() -> UInt64 {
        UInt64(ProcessInfo.processInfo.environment["RKSTRESS_SEED"] ?? "") ?? defaultSeed
    }

    private func emit(_ text: String) {
        let line = "RKSTRESS " + text
        lines.append(line)
        print(line)
        fflush(stdout)
    }

    private func item(_ number: Any, _ scheme: Scheme, _ ok: Bool, _ note: String) {
        emit("C scheme=\(scheme.raw) item=\(number) ok=\(ok ? 1 : 0) note=\(note)")
        XCTAssertTrue(ok, "\(scheme.raw) C\(number): \(note)")
        if !ok { shot("C-\(scheme.raw)-\(number)") }
    }

    private func attachLog(_ name: String) {
        let attachment = XCTAttachment(string: lines.joined(separator: "\n") + "\n")
        attachment.name = "rkstress-\(name).txt"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// At most three screenshots per test, so a bad run does not fill the result bundle.
    private func shot(_ name: String) {
        guard anomalyShots < 3 else { return }
        anomalyShots += 1
        attachScreenshot(name)
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: Checks

    private func checkAlive(_ reading: Reading, _ scheme: Scheme, _ when: String) throws {
        if reading.failed { throw Fatal(description: "\(scheme.raw): could not read the screen \(when)") }
        if !reading.alive {
            shot("\(scheme.raw)-keyboard-gone")
            XCTFail("\(scheme.raw): the keyboard is gone \(when)")
            throw Fatal(description: "\(scheme.raw): the keyboard is gone \(when)")
        }
    }

    private func checkCandidates(_ state: State, _ scheme: Scheme, _ when: String) {
        for text in state.candidates {
            if text.isEmpty || text.unicodeScalars.contains(where: { $0.value == 0xFFFD }) {
                XCTFail("\(scheme.raw): a candidate is empty or contains U+FFFD \(when)")
                shot("\(scheme.raw)-bad-candidate")
                return
            }
        }
    }

    // MARK: Reading the screen

    /// One accessibility snapshot of the whole app: the candidate strip (code and candidates in order), whether the
    /// Chinese page's delete key exists and the frames of the keys, all from a single call.
    private func read() -> Reading {
        var reading = Reading()
        for _ in 0..<3 {
            do {
                let snapshot = try app.snapshot()
                var indexed: [Int: String] = [:]
                walk(snapshot, into: &reading, indexed: &indexed)
                reading.state.candidates = indexed.keys.sorted().compactMap { indexed[$0] }
                return reading
            } catch {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        reading.failed = true
        return reading
    }

    private func walk(_ node: XCUIElementSnapshot, into reading: inout Reading, indexed: inout [Int: String]) {
        let id = node.identifier
        if id.hasPrefix("rk.candidate."), let index = Int(id.dropFirst("rk.candidate.".count)) {
            indexed[index] = node.label
            reading.frames[id] = node.frame
        } else if id == "rk.ime.composing" {
            reading.state.composing = (node.value as? String) ?? ""
        } else if id.hasPrefix("rk.ime.") || id == "rk.space" || id == "rk.return" || id == "rk.zhEn" {
            reading.frames[id] = node.frame
            if id == "rk.ime.backspace" { reading.alive = true }
        }
        for child in node.children { walk(child, into: &reading, indexed: &indexed) }
    }

    /// Polls until the strip differs from `pre` and the same state is read twice in a row; gives up after `timeout`
    /// (then `changed` is false). `ms` is the time until the first read that showed the change (that read itself costs
    /// about a second on the simulator, so it is an upper bound).
    private func settle(from pre: State, timeout: TimeInterval = 1.5, quiet: TimeInterval = 0.05) -> (reading: Reading, ms: Int, changed: Bool) {
        let start = Date()
        var latest = read()
        while true {
            let elapsed = Date().timeIntervalSince(start)
            if latest.state != pre {
                let firstChange = Int(Date().timeIntervalSince(start) * 1000)
                Thread.sleep(forTimeInterval: quiet)
                let confirm = read()
                if confirm.state == latest.state { return (confirm, firstChange, true) }
                latest = confirm
                continue
            }
            if elapsed >= timeout { return (latest, Int(elapsed * 1000), false) }
            Thread.sleep(forTimeInterval: 0.04)
            latest = read()
        }
    }

    // MARK: Fields

    private func testField() -> XCUIElement { app.textFields["rk.home.testInput"] }

    private func fieldText(_ field: XCUIElement) -> String {
        let value = field.value as? String ?? ""
        return value == Self.placeholder ? "" : value
    }

    private func waitForField(_ field: XCUIElement, equalTo expected: String, timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var text = fieldText(field)
        while text != expected, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            text = fieldText(field)
        }
        return text
    }

    private func waitForField(_ field: XCUIElement, notEqualTo previous: String, timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var text = fieldText(field)
        while text == previous, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            text = fieldText(field)
        }
        return text
    }

    /// Empties the field with the delete key (the strip is empty then, so it reaches the field).
    private func clearField(_ field: XCUIElement) throws {
        var guardCount = 0
        while !fieldText(field).isEmpty, guardCount < 120 {
            guardCount += 1
            let before = fieldText(field)
            try tap("rk.ime.backspace")
            _ = waitForField(field, notEqualTo: before, timeout: 2)
        }
        XCTAssertTrue(fieldText(field).isEmpty, "the field could not be emptied")
    }

    // MARK: Taps

    private func tap(_ identifier: String) throws {
        let button = element(identifier)
        guard button.waitForExistence(timeout: 10) else { throw Fatal(description: "\(identifier) not found") }
        button.tap()
    }

    /// Return clears a code, but with no code it is the host's return key and the field gives up the keyboard. So it is
    /// only pressed while the strip shows something.
    private func clearCode(_ state: State) throws {
        guard !state.isEmpty else { return }
        try tap("rk.return")
        _ = settle(from: state)
    }

    private func tapKeys(_ keys: [String]) throws {
        for key in keys { try tap("rk.ime.\(key)") }
    }

    /// Key frames in screen coordinates. The snapshot reports the extension's frames in another space, so one key is
    /// resolved as an element and the difference is applied to all.
    private func screenFrames() throws -> [String: CGRect] {
        let reading = read()
        let probe = "rk.ime.backspace"
        guard let snap = reading.frames[probe] else { throw Fatal(description: "no snapshot frame for \(probe)") }
        let real = element(probe).frame
        let dx = real.minX - snap.minX
        let dy = real.minY - snap.minY
        emit("CAL dx=\(Int(dx)) dy=\(Int(dy)) screen_w=\(Int(app.frame.width)) screen_h=\(Int(app.frame.height))")
        return reading.frames.mapValues { $0.offsetBy(dx: dx, dy: dy) }
    }

    /// A tap at the centre of a key frame taken from an earlier snapshot: no element lookup, so taps can follow each
    /// other as fast as the runner can post them.
    private func fastTap(_ identifier: String, frames: [String: CGRect]) {
        guard let frame = frames[identifier] else {
            XCTFail("\(identifier) has no frame")
            return
        }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
            .tap()
    }

    /// Taps candidate `index`, dragging the strip sideways until it can be hit. Returns false when it never could.
    private func tapCandidate(index: Int) throws -> Bool {
        let button = element("rk.candidate.\(index)")
        guard button.waitForExistence(timeout: 5) else { return false }
        var drags = 0
        let width = app.frame.width
        // The strip's height on screen (the button's own frame; the snapshot's frames are not in screen coordinates).
        let y = button.frame.midY
        while !button.isHittable, drags < 12 {
            let from = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: width * 0.7, dy: y))
            let to = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: width * 0.15, dy: y))
            from.press(forDuration: 0.05, thenDragTo: to)
            drags += 1
            Thread.sleep(forTimeInterval: 0.3)
        }
        guard button.isHittable else { return false }
        // A strip still decelerating swallows the touch (it only stops the scroll), so wait until the button stands still.
        var last = button.frame
        for _ in 0..<15 {
            Thread.sleep(forTimeInterval: 0.15)
            let now = button.frame
            if now == last { break }
            last = now
        }
        button.tap()
        return true
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    // MARK: Steps (the same as ChineseSchemesUITests)

    private func begin(_ scheme: Scheme, name: String) throws {
        addTeardownBlock { @MainActor [weak self] in self?.attachLog(name) }
        launch()
        try chooseMethod(scheme.raw)
        try openKeyboardOnChinesePage()
    }

    private func launch() {
        app = XCUIApplication()
        app.launchArguments += ["-rkSkipOnboarding"]
        app.launch()
        // Whatever fails below, the method goes back to 速成 so the other UI tests start from the default.
        addTeardownBlock { @MainActor [weak self] in self?.restoreQuick() }
    }

    private func chooseMethod(_ rawValue: String) throws {
        let chineseLink = element("rk.home.chineseInput")
        guard chineseLink.waitForExistence(timeout: 10) else { throw Fatal(description: "中文輸入與手寫 link not found") }
        chineseLink.tap()
        let row = element("rk.settings.\(rawValue)")
        guard row.waitForExistence(timeout: 10) else { throw Fatal(description: "rk.settings.\(rawValue) row not found") }
        row.tap()
        app.navigationBars.buttons.firstMatch.tap()
    }

    private func restoreQuick() {
        guard let app, app.state == .runningForeground else { return }
        let chineseLink = element("rk.home.chineseInput")
        var steps = 0
        while !chineseLink.waitForExistence(timeout: 1), steps < 3 {
            steps += 1
            let back = app.navigationBars.buttons.firstMatch
            guard back.exists else { break }
            back.tap()
        }
        guard chineseLink.exists else { return }
        chineseLink.tap()
        let row = element("rk.settings.quick")
        guard row.waitForExistence(timeout: 5) else { return }
        row.tap()
    }

    private func openKeyboardOnChinesePage() throws {
        let testInputLink = element("rk.home.testInputLink")
        guard testInputLink.waitForExistence(timeout: 10) else { throw Fatal(description: "測試輸入 link not found") }
        testInputLink.tap()
        let field = testField()
        guard field.waitForExistence(timeout: 10) else { throw Fatal(description: "the 測試輸入 field was not found") }
        field.tap()
        try openOurKeyboardInLocalMode()
        if !element("rk.ime.backspace").exists {
            let zhEn = element("rk.zhEn")
            guard zhEn.waitForExistence(timeout: 5) else { throw Fatal(description: "中英 key not found") }
            zhEn.tap()
        }
        guard element("rk.ime.backspace").waitForExistence(timeout: 10) else { throw Fatal(description: "the Chinese page did not show") }
    }

    private func openOurKeyboardInLocalMode() throws {
        let mode = element("rk.mode")
        var found = mode.waitForExistence(timeout: 5)
        var tries = 0
        while !found && tries < 6 {
            tries += 1
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 2)
            guard let next = nextKeyboardButton() else { break }
            next.tap()
            found = mode.waitForExistence(timeout: 2)
        }
        guard found else { throw Fatal(description: "Remote Keyboard is not reachable from the globe key") }
        if (mode.value as? String) != Self.localModeValue {
            mode.tap()
            let deadline = Date().addingTimeInterval(5)
            while (mode.value as? String) != Self.localModeValue, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        }
        guard (mode.value as? String) == Self.localModeValue else { throw Fatal(description: "could not switch to Local mode") }
    }

    private func nextKeyboardButton() -> XCUIElement? {
        guard app.keyboards.firstMatch.exists else { return nil }
        let minY = app.frame.minY + app.frame.height * 0.85
        for name in Self.nextKeyboardNames {
            let inside = app.keyboards.buttons[name]
            if inside.exists { return inside }
            let query = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", name, name))
            for button in query.allElementsBoundByIndex.prefix(10) where button.frame.minY >= minY { return button }
        }
        return nil
    }
}
