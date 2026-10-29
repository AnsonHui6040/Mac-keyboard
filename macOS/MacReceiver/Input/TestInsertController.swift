import Foundation
import OSLog
import RemoteKeyboardCore

/// One entry of the menu bar "Test Insert" submenu.
struct TestInsertItem: Identifiable, Equatable {
    let id: String
    let label: String
    let text: String
    /// False sends the whole string as a single CGEvent (O5 length test).
    let chunked: Bool

    static let o5Text = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123"

    static let all: [TestInsertItem] = [
        TestInsertItem(id: "a", label: "A", text: "A", chunked: true),
        TestInsertItem(id: "hello", label: "Hello", text: "Hello", chunked: true),
        TestInsertItem(id: "hk", label: "香港", text: "香港", chunked: true),
        TestInsertItem(id: "family", label: "👨‍👩‍👧‍👦", text: "👨‍👩‍👧‍👦", chunked: true),
        TestInsertItem(id: "cafe", label: "café", text: "café", chunked: true),
        TestInsertItem(id: "o5", label: "O5 長度測試（30 字元，單一事件）", text: o5Text, chunked: false),
    ]
}

/// Menu driven injection check: 3 s countdown, then a fresh focus read, `FocusGuard`, ASCII switch, inject.
@MainActor
final class TestInsertController: ObservableObject {
    static let countdownSeconds = 3
    static let settleKey = "rk.settleSeconds"
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard.receiver", category: "inject")

    @Published private(set) var remaining: Int?
    @Published private(set) var status = "待命"

    private let focus: FocusMonitor
    private let injector: TextInjector
    private let switcher: InputSourceSwitcher
    private let defaults: UserDefaults
    private var timer: Timer?
    private var pending: TestInsertItem?

    init(
        focus: FocusMonitor,
        injector: TextInjector = TextInjector(),
        switcher: InputSourceSwitcher = InputSourceSwitcher(
            controller: TISInputSourceController(),
            settle: { try? await Task.sleep(for: .seconds($0)) }
        ),
        defaults: UserDefaults = .standard
    ) {
        self.focus = focus
        self.injector = injector
        self.switcher = switcher
        self.defaults = defaults
    }

    var isCounting: Bool { remaining != nil }

    /// `defaults write com.ansonhui.remotekeyboard.receiver rk.settleSeconds -float 0.1` overrides the default for Step 8 tuning.
    var settleSeconds: Double {
        let override = defaults.double(forKey: Self.settleKey)
        return override > 0 ? override : InputSourceSwitcher.defaultSettleSeconds
    }

    func start(_ item: TestInsertItem) {
        if !focus.refreshNow().axTrusted {
            focus.requestTrustPrompt()
            status = "輔助使用未授權"
            return
        }
        cancel()
        pending = item
        remaining = Self.countdownSeconds
        status = "倒數中，請點進要插入的欄位"
        timer = CommonModeTimer.make(1, repeats: true) { [weak self] in self?.tick() }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        pending = nil
        if remaining != nil { status = "已取消" }
        remaining = nil
    }

    private func tick() {
        guard let current = remaining else { return }
        if current > 1 {
            remaining = current - 1
            return
        }
        timer?.invalidate()
        timer = nil
        remaining = nil
        guard let item = pending else { return }
        pending = nil
        Task { await run(item) }
    }

    private func run(_ item: TestInsertItem) async {
        // Fresh AX read, not the 250 ms cached snapshot: the user may have switched windows a moment ago.
        let snapshot = focus.refreshNow()
        let decision = FocusGuard.authorize(eventEpoch: nil, current: snapshot)
        guard decision == .allow else {
            status = "未插入：\(FocusMenuText.reason(decision))"
            Self.log.info("test insert refused \(String(describing: decision), privacy: .public)")
            return
        }
        var posted = false
        var chunks = 0
        let started = ContinuousClock.now
        let result = await switcher.withASCII(settleSeconds: settleSeconds) {
            if item.chunked {
                let outcome = injector.insert(item.text)
                chunks = outcome.posted
                posted = outcome.complete
            } else {
                posted = injector.insertUnchunked(item.text)
                chunks = posted ? 1 : 0
            }
        }
        let elapsed = ContinuousClock.now - started
        let ms = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        switch result {
        case .switchFailed:
            status = "未插入：切換英文輸入法失敗"
        case .compositionActive:
            status = "未插入：輸入法正在組字"
        case .injected:
            let length = item.text.utf16.count
            status = posted ? "已插入（長度 \(length)，\(chunks) 段，\(ms) ms）" : "插入失敗：事件建立失敗"
        }
        Self.log.info("test insert \(item.id, privacy: .public) result \(String(describing: result), privacy: .public) ms \(ms, privacy: .public)")
    }
}
