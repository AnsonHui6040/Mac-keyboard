import XCTest
@testable import RemoteKeyboardCore

private let zhuyin = "com.apple.inputmethod.TCIM.Zhuyin"

/// Records every call into one shared log so ordering across switcher, injector and settle is checkable.
@MainActor
private final class FakeController: InputSourceControlling {
    var current: String
    var selected: [String] = []
    var selectSucceeds = true
    /// When true, `select` reports success but leaves `current` unchanged.
    var selectIgnored = false
    var log: [String] = []

    init(current: String) { self.current = current }

    func currentID() -> String { current }
    func select(_ id: String) -> Bool {
        selected.append(id)
        log.append("select:\(id == InputSourceSwitcher.asciiID ? "ABC" : "Zhuyin")")
        guard selectSucceeds else { return false }
        if !selectIgnored { current = id }
        return true
    }
}

/// Scripted composition state; `states` is consumed one read at a time and the last value repeats.
@MainActor
private final class FakeComposition: CompositionControlling {
    var states: [CompositionState]
    var stateReads = 0
    var cancels = 0
    let log: () -> Void

    init(_ states: [CompositionState], onCancel: @escaping () -> Void = {}) {
        self.states = states
        self.log = onCancel
    }

    func state() -> CompositionState {
        stateReads += 1
        return states.count > 1 ? states.removeFirst() : (states.first ?? .unknown)
    }

    func cancel() { cancels += 1; log() }
}

@MainActor
final class InputSourceSwitcherTests: XCTestCase {
    func testAlreadyABCDoesNotSwitch() async {
        let fake = FakeController(current: InputSourceSwitcher.asciiID)
        var injected = 0
        let switcher = InputSourceSwitcher(controller: fake, settle: { _ in })
        let result = await switcher.withASCII(settleSeconds: 0.05) { injected += 1 }
        XCTAssertEqual(result, .injected)
        XCTAssertEqual(fake.selected, [])
        XCTAssertEqual(injected, 1)
    }

    func testSwitchesAndRestores() async {
        let fake = FakeController(current: zhuyin)
        var injected = 0
        let switcher = InputSourceSwitcher(controller: fake, settle: { _ in })
        let result = await switcher.withASCII(settleSeconds: 0.05) { injected += 1 }
        XCTAssertEqual(result, .injected)
        XCTAssertEqual(fake.selected, [InputSourceSwitcher.asciiID, zhuyin])
        XCTAssertEqual(injected, 1)
        XCTAssertEqual(fake.current, zhuyin)
    }

    func testVerifyFailureDoesNotInject() async {
        let fake = FakeController(current: zhuyin)
        fake.selectIgnored = true
        var injected = 0
        let switcher = InputSourceSwitcher(controller: fake, settle: { _ in })
        let result = await switcher.withASCII(settleSeconds: 0.05) { injected += 1 }
        XCTAssertEqual(result, .switchFailed)
        XCTAssertEqual(injected, 0)
        XCTAssertNotEqual(fake.selected.last, InputSourceSwitcher.asciiID)
        XCTAssertEqual(fake.selected, [InputSourceSwitcher.asciiID, zhuyin])
    }

    func testSelectReturningFalseDoesNotInject() async {
        let fake = FakeController(current: zhuyin)
        fake.selectSucceeds = false
        var injected = 0
        let switcher = InputSourceSwitcher(controller: fake, settle: { _ in })
        let result = await switcher.withASCII(settleSeconds: 0.05) { injected += 1 }
        XCTAssertEqual(result, .switchFailed)
        XCTAssertEqual(injected, 0)
    }

    func testRestoreHappensAfterSettleDelay() async {
        let fake = FakeController(current: zhuyin)
        let switcher = InputSourceSwitcher(controller: fake, settle: { seconds in
            fake.log.append("settle:\(seconds)")
        })
        _ = await switcher.withASCII(settleSeconds: 0.05) { fake.log.append("inject") }
        XCTAssertEqual(fake.log, ["select:ABC", "inject", "settle:0.05", "select:Zhuyin"])
    }

    func testOverlappingCallsAreSerializedEachWithOwnSettleBeforeRestore() async {
        let fake = FakeController(current: zhuyin)
        let switcher = InputSourceSwitcher(controller: fake, settle: { seconds in
            fake.log.append("settle:\(seconds)")
            // Suspend long enough for the second call to start while the first is still settling.
            for _ in 0..<5 { await Task.yield() }
        })
        let first = Task { await switcher.withASCII(settleSeconds: 0.05) { fake.log.append("injectA") } }
        let second = Task { await switcher.withASCII(settleSeconds: 0.05) { fake.log.append("injectB") } }
        let results = await [first.value, second.value]
        XCTAssertEqual(results, [.injected, .injected])
        XCTAssertEqual(fake.log, [
            "select:ABC", "injectA", "settle:0.05", "select:Zhuyin",
            "select:ABC", "injectB", "settle:0.05", "select:Zhuyin",
        ])
        XCTAssertEqual(fake.current, zhuyin)
    }

    func testFailedCallStillReleasesTheGate() async {
        let fake = FakeController(current: zhuyin)
        fake.selectIgnored = true
        let switcher = InputSourceSwitcher(controller: fake, settle: { _ in })
        var injected = 0
        let first = Task { await switcher.withASCII { injected += 1 } }
        let second = Task { await switcher.withASCII { injected += 1 } }
        let results = await [first.value, second.value]
        XCTAssertEqual(results, [.switchFailed, .switchFailed])
        XCTAssertEqual(injected, 0)
    }

    func testDefaultSettleIsFiftyMilliseconds() { XCTAssertEqual(InputSourceSwitcher.defaultSettleSeconds, 0.05) }

    // MARK: Composition (D4 revision)

    func testComposingIsCancelledBeforeSwitch() async {
        let fake = FakeController(current: zhuyin)
        let composition = FakeComposition([.composing, .notComposing]) { fake.log.append("cancel") }
        let switcher = InputSourceSwitcher(controller: fake, composition: composition, settle: { seconds in
            fake.log.append("settle:\(seconds)")
        })
        let result = await switcher.withASCII(settleSeconds: 0.05) { fake.log.append("inject") }
        XCTAssertEqual(result, .injected)
        XCTAssertEqual(fake.log, ["cancel", "settle:0.05", "select:ABC", "inject", "settle:0.05", "select:Zhuyin"])
        XCTAssertEqual(composition.cancels, 1)
    }

    func testStillComposingAfterCancelRefuses() async {
        let fake = FakeController(current: zhuyin)
        let composition = FakeComposition([.composing])
        var injected = 0
        let switcher = InputSourceSwitcher(controller: fake, composition: composition, settle: { _ in })
        let result = await switcher.withASCII(settleSeconds: 0.05) { injected += 1 }
        XCTAssertEqual(result, .compositionActive)
        XCTAssertEqual(fake.selected, [])
        XCTAssertEqual(injected, 0)
        XCTAssertEqual(composition.cancels, 1)
    }

    func testUnknownCompositionSwitchesAsBefore() async {
        let fake = FakeController(current: zhuyin)
        let composition = FakeComposition([.unknown])
        var injected = 0
        let switcher = InputSourceSwitcher(controller: fake, composition: composition, settle: { _ in })
        let result = await switcher.withASCII(settleSeconds: 0.05) { injected += 1 }
        XCTAssertEqual(result, .injected)
        XCTAssertEqual(fake.selected, [InputSourceSwitcher.asciiID, zhuyin])
        XCTAssertEqual(injected, 1)
        XCTAssertEqual(composition.cancels, 0)
    }

    func testNotComposingSwitchesWithoutCancel() async {
        let fake = FakeController(current: zhuyin)
        let composition = FakeComposition([.notComposing])
        let switcher = InputSourceSwitcher(controller: fake, composition: composition, settle: { _ in })
        let result = await switcher.withASCII(settleSeconds: 0.05) {}
        XCTAssertEqual(result, .injected)
        XCTAssertEqual(composition.cancels, 0)
    }

    func testABCSkipsCompositionCheck() async {
        let fake = FakeController(current: InputSourceSwitcher.asciiID)
        let composition = FakeComposition([.composing])
        var injected = 0
        let switcher = InputSourceSwitcher(controller: fake, composition: composition, settle: { _ in })
        let result = await switcher.withASCII(settleSeconds: 0.05) { injected += 1 }
        XCTAssertEqual(result, .injected)
        XCTAssertEqual(composition.stateReads, 0)
        XCTAssertEqual(composition.cancels, 0)
        XCTAssertEqual(injected, 1)
    }

    func testCompositionRefusalReleasesTheGate() async {
        let fake = FakeController(current: zhuyin)
        let composition = FakeComposition([.composing])
        let switcher = InputSourceSwitcher(controller: fake, composition: composition, settle: { _ in })
        let first = Task { await switcher.withASCII {} }
        let second = Task { await switcher.withASCII {} }
        let results = await [first.value, second.value]
        XCTAssertEqual(results, [.compositionActive, .compositionActive])
    }

    func testRestoreFailureStillReturnsInjected() async {
        let fake = FakeController(current: zhuyin)
        let switcher = InputSourceSwitcher(controller: fake, settle: { _ in })
        var injected = 0
        let result = await switcher.withASCII {
            injected += 1
            fake.selectSucceeds = false
        }
        XCTAssertEqual(result, .injected)
        XCTAssertEqual(injected, 1)
    }

    func testUnauthorizedAfterGateRefusesBeforeCancelSwitchOrInject() async {
        let fake = FakeController(current: zhuyin)
        let composition = FakeComposition([.composing])
        var injected = 0
        var checks = 0
        let switcher = InputSourceSwitcher(controller: fake, composition: composition, settle: { _ in })
        let result = await switcher.withASCII(settleSeconds: 0.05, isAuthorized: { checks += 1; return false }) { injected += 1 }
        XCTAssertEqual(result, .refused)
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(composition.cancels, 0)
        XCTAssertEqual(fake.selected, [])
        XCTAssertEqual(injected, 0)
    }

    func testAuthorizedClosureTrueLetsCancelAndSwitchProceed() async {
        let fake = FakeController(current: zhuyin)
        let composition = FakeComposition([.composing, .notComposing])
        var injected = 0
        let switcher = InputSourceSwitcher(controller: fake, composition: composition, settle: { _ in })
        let result = await switcher.withASCII(isAuthorized: { true }) { injected += 1 }
        XCTAssertEqual(result, .injected)
        XCTAssertEqual(composition.cancels, 1)
        XCTAssertEqual(injected, 1)
    }
}
