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
    static let pageDefaultsKey = "rk.page"
    static let transmitDefaultsKey = "rk.transmit"
    private static let noteSeconds: Double = 2
    /// There is no Chinese page yet; `中英` stays disabled until one exists.
    private static let chineseAvailable = false

    private var rootView: KeyboardRootView?
    private var heightConstraint: NSLayoutConstraint?
    private let peripheral = KeyboardBLEPeripheral.shared
    /// Counts this controller and releases peripheral ownership when it is deallocated.
    private let lifecycle = ControllerLifecycle()
    private lazy var router = InputRouter(local: TextDocumentProxySink(proxy: textDocumentProxy), remote: peripheral)
    private var savedMode: KeyboardMode = .local
    private var transmit: TransmitMode = .instant
    private var navigator = PageNavigator(lastPage: nil, field: .text, chineseAvailable: KeyboardViewController.chineseAvailable)
    /// Text typed in Remote mode and not sent yet. Memory only: it dies with this controller and is never written out.
    private var draft = DraftBuffer()
    /// A short-lived line shown after the status, such as the last ack. Cleared by `noteTask`.
    private var note: String?
    private var noteTask: Task<Void, Never>?
    /// Between `viewWillAppear` and `viewDidDisappear`; only a controller on screen may reclaim the peripheral.
    private var isOnScreen = false

    /// Remote only counts with Full Access; without it the keyboard is Local and types as before.
    private var mode: KeyboardMode { ModeResolver.effectiveMode(saved: savedMode, hasFullAccess: hasFullAccess) }
    private var isReady: Bool { peripheral.isRemoteReady(for: lifecycle.token) }

    override func viewDidLoad() {
        super.viewDidLoad()
        let defaults = UserDefaults.standard
        savedMode = ModeResolver.saved(rawValue: defaults.string(forKey: Self.modeDefaultsKey))
        transmit = TransmitMode.stored(rawValue: defaults.string(forKey: Self.transmitDefaultsKey))
        updateNavigator()

        let root = KeyboardRootView()
        root.onAction = { [weak self] action in self?.perform(action) ?? false }
        #if DEBUG
        root.onDebugLongReturn = { [weak self] in self?.sendDebugLongText() }
        #endif
        root.globeButton.addTarget(
            self,
            action: #selector(handleInputModeList(from:with:)),
            for: .allTouchEvents
        )

        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        let height = view.heightAnchor.constraint(equalToConstant: root.preferredHeight)
        // Below required, so the system's own sizing constraint on the input view never breaks.
        height.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            height,
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            root.topAnchor.constraint(equalTo: view.topAnchor),
            root.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        rootView = root
        heightConstraint = height
        refreshStatus()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isOnScreen = true
        updateNavigator()
        claimPeripheral()
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
        rootView?.setGlobeVisible(needsInputModeSwitchKey)
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
        KeyboardLifecycleLog.note(.vacantOwnerReclaimed(owner: lifecycle.token))
        claimPeripheral()
        refreshStatus()
    }

    #if DEBUG
    /// T07 check: one `TEXT` of 3,000 characters (6,000 UTF-8 bytes) in a single message, many frames.
    private func sendDebugLongText() {
        reclaimPeripheralIfVacant()
        guard mode == .remote, isReady else {
            showNote("Mac 尚未就緒，未輸入")
            return
        }
        peripheral.send(.text(String(repeating: "一二三四五六七八九十ABCDEFGHIJ", count: 150)))
    }
    #endif

    // MARK: Pages

    /// Starts from the saved letter page; the field type may override it (email and URL open English, numbers open symbols).
    private func updateNavigator() {
        let last = KeyboardPage.stored(rawValue: UserDefaults.standard.string(forKey: Self.pageDefaultsKey))
        navigator = PageNavigator(lastPage: last, field: fieldKind(), chineseAvailable: Self.chineseAvailable)
    }

    private func fieldKind() -> FieldKind {
        switch textDocumentProxy.keyboardType ?? .default {
        case .emailAddress, .URL, .webSearch: .emailOrURL
        case .numberPad, .decimalPad, .numbersAndPunctuation, .asciiCapableNumberPad: .number
        default: .text
        }
    }

    // MARK: Keys

    /// Returns whether the key was taken: `false` when the draft was full or the key was refused.
    @discardableResult
    private func perform(_ action: KeyAction) -> Bool {
        reclaimPeripheralIfVacant()
        let outcome = router.route(action, mode: mode, transmit: transmit, ready: isReady, draft: &draft)
        handle(outcome, for: action)
        return outcome != .draftFull && outcome != .rejected
    }

    private func handle(_ outcome: RouteOutcome, for action: KeyAction) {
        switch outcome {
        case .modeToggled(let requested):
            // Persist what actually took effect, so a refused Remote (no Full Access) is not remembered as Remote.
            let applied = ModeResolver.effectiveMode(saved: requested, hasFullAccess: hasFullAccess)
            savedMode = applied
            UserDefaults.standard.set(applied.rawValue, forKey: Self.modeDefaultsKey)
            showNote(requested == .remote && applied == .local ? "遠端需要開啟「允許完整取用」" : nil)
        case .transmitToggled(let requested):
            transmit = requested
            UserDefaults.standard.set(requested.rawValue, forKey: Self.transmitDefaultsKey)
            refreshStatus()
        case .pageChanged:
            if action == .switchSymbols { navigator.switchSymbols() } else { navigator.switchChineseEnglish() }
            UserDefaults.standard.set(navigator.persistablePage.storageValue, forKey: Self.pageDefaultsKey)
            refreshStatus()
        case .draftFull:
            showNote("草稿已達 1,000 字上限")
        case .rejected:
            // A draft key pressed in Local mode does nothing and says nothing; so does 傳送 on an empty draft
            // while the Mac is ready (the button is grey then anyway).
            if mode == .remote, !isReady { showNote("Mac 尚未就緒，未輸入") }
        case .draftEdited, .draftSent:
            refreshStatus()
        case .insertedLocally, .enqueuedRemote, .advanceInputMode:
            break
        }
    }

    private func received(_ message: ControlMessage) {
        // A probe's answer has no wording, so it leaves the status line alone.
        if case .ack(let ack) = message, let text = StatusLine.ackText(ack.result) { showNote(text) }
        refreshStatus()
    }

    // MARK: View state

    private func refreshStatus() {
        guard let rootView else { return }
        let link = peripheral.linkState
        let line = StatusLine.text(
            mode: mode, link: link, receiver: peripheral.latestStatus, connectedMs: peripheral.reconnectLatencyMs,
            paired: peripheral.isPaired)
        let state = KeyboardViewState(
            mode: mode,
            transmit: transmit,
            page: navigator.page,
            top: TopAreaState(
                mode: mode, transmit: transmit, ready: isReady, draftEmpty: draft.isEmpty, hasNote: note != nil),
            draft: draft,
            statusText: StatusLine.appendingNote(line, note: note),
            linkName: link.name,
            probeText: Self.probeStatusText(),
            showsGlobe: needsInputModeSwitchKey,
            chineseAvailable: Self.chineseAvailable,
            hapticsEnabled: hasFullAccess)
        rootView.apply(state)
        let height = rootView.preferredHeight
        if heightConstraint?.constant != height { heightConstraint?.constant = height }
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
        let value = UserDefaults(suiteName: AppGroup.identifier)?.object(forKey: AppGroup.Key.probe)
        let group = value == nil ? "AppGroup: NIL" : "AppGroup: OK"
        return "\(group)  版本 \(BuildStamp.current())"
    }
}
