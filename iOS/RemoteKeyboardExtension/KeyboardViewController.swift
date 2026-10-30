import UIKit
import RemoteKeyboardCore

/// Adapts the system text proxy to the Core `TextSink` protocol.
@MainActor
struct TextDocumentProxySink: @preconcurrency TextSink {
    let proxy: UITextDocumentProxy
    func insertText(_ text: String) { proxy.insertText(text) }
    func deleteBackward() { proxy.deleteBackward() }
}

final class KeyboardViewController: UIInputViewController {
    static let modeDefaultsKey = "rk.mode"
    private static let noteSeconds: Double = 2

    private var keyboardView: MinimalKeyboardView?
    private let peripheral = KeyboardBLEPeripheral.shared
    /// Counts this controller and releases peripheral ownership when it is deallocated.
    private let lifecycle = ControllerLifecycle()
    private var savedMode: KeyboardMode = .local
    /// A short-lived line shown after the status, such as the last ack. Cleared by `noteTask`.
    private var note: String?
    private var noteTask: Task<Void, Never>?
    /// Between `viewWillAppear` and `viewDidDisappear`; only a controller on screen may reclaim the peripheral.
    private var isOnScreen = false

    /// Remote only counts with Full Access; without it the keyboard is Local and types as before.
    private var mode: KeyboardMode { ModeResolver.effectiveMode(saved: savedMode, hasFullAccess: hasFullAccess) }

    override func viewDidLoad() {
        super.viewDidLoad()
        savedMode = ModeResolver.saved(rawValue: UserDefaults.standard.string(forKey: Self.modeDefaultsKey))

        let router = KeyboardActionRouter(
            local: TextDocumentProxySink(proxy: textDocumentProxy),
            remote: peripheral,
            isRemoteReady: { [weak self] in
                guard let self else { return false }
                return self.peripheral.isRemoteReady(for: self.lifecycle.token)
            }
        )
        let view = MinimalKeyboardView(
            showsGlobeKey: needsInputModeSwitchKey,
            probeText: Self.probeStatusText()
        )
        view.onAction = { [weak self] action in
            guard let self else { return }
            self.reclaimPeripheralIfVacant()
            self.handle(router.route(action, mode: self.mode))
        }
        #if DEBUG
        view.onDebugLongReturn = { [weak self] in self?.sendDebugLongText() }
        #endif
        view.globeButton.addTarget(
            self,
            action: #selector(handleInputModeList(from:with:)),
            for: .allTouchEvents
        )

        view.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            view.topAnchor.constraint(equalTo: self.view.topAnchor),
            view.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
        ])
        keyboardView = view
        view.setMode(mode)
        refreshStatus()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isOnScreen = true
        claimPeripheral()
        keyboardView?.setMode(mode)
        refreshStatus()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reclaimPeripheralIfVacant()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        peripheral.disappear(owner: lifecycle.token)
        showNote(nil)
    }

    override func viewWillLayoutSubviews() {
        keyboardView?.setGlobeVisible(needsInputModeSwitchKey)
        super.viewWillLayoutSubviews()
    }

    private func claimPeripheral() {
        peripheral.appear(
            owner: lifecycle.token, hasFullAccess: hasFullAccess,
            onStateChange: { [weak self] _ in self?.refreshStatus() },
            onControl: { [weak self] message in self?.received(message) },
            onNote: { [weak self] text in self?.showNote(text) }
        )
    }

    /// If a newer controller claimed the peripheral and then disappeared while this one stayed on screen, nobody owns
    /// the link any more. The next key press (or `viewDidAppear`) takes it back, instead of leaving this keyboard offline.
    private func reclaimPeripheralIfVacant() {
        guard isOnScreen, peripheral.isVacant else { return }
        KeyboardLifecycleLog.note("vacant owner reclaimed by \(lifecycle.token.uuidString.prefix(8))")
        claimPeripheral()
        refreshStatus()
    }

    #if DEBUG
    /// T07 check: one `TEXT` of 3,000 characters (6,000 UTF-8 bytes) in a single message, many frames.
    private func sendDebugLongText() {
        reclaimPeripheralIfVacant()
        guard mode == .remote, peripheral.isRemoteReady(for: lifecycle.token) else {
            showNote("Mac 尚未就緒，未輸入")
            return
        }
        peripheral.send(.text(String(repeating: "一二三四五六七八九十ABCDEFGHIJ", count: 150)))
    }
    #endif

    // MARK: Routing results

    private func handle(_ outcome: RouteOutcome) {
        switch outcome {
        case .modeToggled(let requested):
            // Persist what actually took effect, so a refused Remote (no Full Access) is not remembered as Remote.
            let applied = ModeResolver.effectiveMode(saved: requested, hasFullAccess: hasFullAccess)
            savedMode = applied
            UserDefaults.standard.set(applied.rawValue, forKey: Self.modeDefaultsKey)
            keyboardView?.setMode(applied)
            showNote(requested == .remote && applied == .local ? "遠端需要開啟「允許完整取用」" : nil)
        case .rejected:
            showNote("Mac 尚未就緒，未輸入")
        case .insertedLocally, .enqueuedRemote, .advanceInputMode:
            break
        }
    }

    private func received(_ message: ControlMessage) {
        // A probe's answer has no wording, so it leaves the status line alone.
        if case .ack(let ack) = message, let text = StatusLine.ackText(ack.result) { showNote(text) }
        refreshStatus()
    }

    // MARK: Status line

    private func refreshStatus() {
        let link = peripheral.linkState
        let line = StatusLine.text(
            mode: mode, link: link, receiver: peripheral.latestStatus, connectedMs: peripheral.reconnectLatencyMs)
        keyboardView?.setStatus(text: StatusLine.appendingNote(line, note: note), linkName: link.name)
    }

    private func showNote(_ text: String?) {
        noteTask?.cancel()
        note = text
        refreshStatus()
        guard text != nil else { return }
        noteTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.noteSeconds))
            guard !Task.isCancelled else { return }
            self?.note = nil
            self?.refreshStatus()
        }
    }

    private static func probeStatusText() -> String {
        let value = UserDefaults(suiteName: "group.com.ansonhui.remotekeyboard")?.object(forKey: "probe")
        let group = value == nil ? "AppGroup: NIL" : "AppGroup: OK"
        return "\(group)  版本 \(BuildStamp.current())"
    }
}
