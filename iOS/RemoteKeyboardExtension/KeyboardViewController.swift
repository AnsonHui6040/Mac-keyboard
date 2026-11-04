import UIKit
import RemoteKeyboardCore
import os

/// Adapts the system text proxy to the Core `TextSink` protocol.
@MainActor
struct TextDocumentProxySink: @preconcurrency TextSink {
    let proxy: UITextDocumentProxy
    func insertText(_ text: String) { proxy.insertText(text) }
    func deleteBackward() { proxy.deleteBackward() }
}

#if DEBUG
/// Debug panel: forwards to the peripheral and reports the id of each event it sent, so acks can be matched to them.
@MainActor
final class ProbingRemoteSink: @preconcurrency RemoteEventSink {
    private let peripheral: KeyboardBLEPeripheral
    private let onSent: (UUID) -> Void
    init(peripheral: KeyboardBLEPeripheral, onSent: @escaping (UUID) -> Void) {
        self.peripheral = peripheral
        self.onSent = onSent
    }
    func enqueue(_ kind: EventKind) {
        if let id = peripheral.send(kind) { onSent(id) }
    }
}
#endif

final class KeyboardViewController: UIInputViewController {
    static let modeDefaultsKey = "rk.mode"
    static let pageDefaultsKey = "rk.page"
    static let transmitDefaultsKey = "rk.transmit"
    private static let noteSeconds: Double = 2
    /// The Chinese methods this build contains.
    private static let installedMethods: Set<ChineseInputMethodID> = [.handwriting, .quick]
    /// ML Kit's model is moved through the App Group, which needs Full Access.
    private static let handwritingNeedsFullAccess = true

    private var rootView: KeyboardRootView?
    private var heightConstraint: NSLayoutConstraint?
    private let peripheral = KeyboardBLEPeripheral.shared
    /// The touchpad page: its gestures, its channel to the Mac and its state. Inactive until 觸控板 is tapped.
    private lazy var trackpad = TrackpadCoordinator(peripheral: peripheral)
    /// Counts this controller and releases peripheral ownership when it is deallocated.
    private let lifecycle = ControllerLifecycle()
    #if DEBUG
    private lazy var router = InputRouter(
        local: TextDocumentProxySink(proxy: textDocumentProxy),
        remote: ProbingRemoteSink(peripheral: peripheral, onSent: { [weak self] id in self?.dictationSent(id) }))
    #else
    private lazy var router = InputRouter(local: TextDocumentProxySink(proxy: textDocumentProxy), remote: peripheral)
    #endif
    private var savedMode: KeyboardMode = .local
    private var transmit: TransmitMode = .instant
    private var navigator = PageNavigator(lastPage: nil, field: .text, chineseAvailable: false)
    private let chinese = ChineseInputCoordinator()
    /// The Chinese method this appearance of the keyboard uses; read from the host App's setting when the keyboard
    /// appears, so a changed setting takes effect the next time the keyboard opens.
    private var activeChineseMethod: ChineseInputMethodID?
    /// Quick (速成): the pure input method, created when the Chinese page first needs it (the table loads in a few ms).
    private var quick: QuickInputMethod?
    private var quickOutput = IMEOutput()
    /// Keys that wait behind an input-method key (a space that waits for a recognition) run in order through this.
    private let imeQueue = OrderedActionQueue()
    /// Text typed in Remote mode and not sent yet. Memory only: it dies with this controller and is never written out.
    private var draft = DraftBuffer()
    /// A short-lived line shown after the status, such as the last ack. Cleared by `noteTask`.
    private var note: String?
    private var noteTask: Task<Void, Never>?
    /// Between `viewWillAppear` and `viewDidDisappear`; only a controller on screen may reclaim the peripheral.
    private var isOnScreen = false
    // Dictation sync (D18). Memory holds the text snapshot; nothing about the text is ever written out or logged.
    private static let dictationLog = Logger(subsystem: "com.ansonhui.remotekeyboard", category: "dictation")
    /// The raw App Group value of 「聽寫同步到 Mac」, read in `viewDidLoad` and `viewWillAppear`.
    private var dictationStoredSetting: Any?
    /// Whether the sync was active at the last `viewWillAppear`; a sync that was off then and is on now starts fresh.
    private var dictationWasActive = false
    private var dictationMirror = DictationMirror()
    /// True while a diff is routed, so only those events count for checklist item 5.
    private var isSyncingDictation = false
    #if DEBUG
    // Debug checklist panel (long press on the status label). It only shows counts; the sync does not depend on it.
    // UserDefaults holds only the on flag and the counters, so a keyboard that iOS rebuilds during dictation still
    // shows the numbers.
    private static let dictationOnKey = "rk.dictationProbeOn"
    /// Wall-clock time the panel was turned on; the switch is only restored for `DictationMirror.leaseSeconds`.
    private static let dictationOnAtKey = "rk.dictationProbeOnAt"
    private static let dictationCountersKey = "rk.dictationProbeCounters"
    private var dictationProbeOn = false
    private var dictationSentIds: Set<UUID> = []
    /// T15: the 10,000-line burst (long press on 換行 for four seconds).
    private let burst = BurstGenerator()
    /// TP1: the M4 test surface while it covers the keyboard.
    private var measureTouchView: MeasurementTouchView?
    #endif

    /// Remote only counts with Full Access; without it the keyboard is Local and types as before.
    private var mode: KeyboardMode { ModeResolver.effectiveMode(saved: savedMode, hasFullAccess: hasFullAccess) }
    private var isReady: Bool { peripheral.isRemoteReady(for: lifecycle.token) }
    /// The Mac says typing cannot go anywhere (password field, secure input, locked screen): text never enters the draft.
    private var isBlocked: Bool { mode == .remote && peripheral.latestStatus?.inputBlocked == true }
    /// The sync runs in Remote mode with 「聽寫同步到 Mac」 on (the same in Debug and Release).
    private var dictationActive: Bool { DictationSync.isActive(mode: mode, storedSetting: dictationStoredSetting) }

    /// The system plays the input click only when the input view itself adopts `UIInputViewAudioFeedback`; a subview
    /// that adopts it is ignored.
    override func loadView() {
        let input = ClickableInputView(frame: .zero, inputViewStyle: .keyboard)
        inputView = input
        view = input
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let defaults = UserDefaults.standard
        savedMode = ModeResolver.saved(rawValue: defaults.string(forKey: Self.modeDefaultsKey))
        transmit = TransmitMode.stored(rawValue: defaults.string(forKey: Self.transmitDefaultsKey))
        updateNavigator()
        dictationStoredSetting = Self.storedDictationSetting()

        let root = KeyboardRootView()
        root.onAction = { [weak self] action in self?.perform(action) ?? false }
        root.onStrokeBegan = { [weak self] in self?.chinese.session.strokeBegan() }
        root.onStrokesEnded = { [weak self] strokes, size in self?.chinese.session.strokesEnded(strokes, size: size) }
        root.onSelectCandidate = { [weak self] index in self?.enqueueIME(.selectCandidate(index)) }
        root.onClearInk = { [weak self] in self?.enqueueIME(.clear) }
        root.onIMEInput = { [weak self] input in self?.enqueueIME(input) }
        chinese.onChange = { [weak self] in self?.refreshStatus() }
        chinese.onClearInk = { [weak self] in self?.rootView?.clearInk() }
        root.onTrackpadToggle = { [weak self] in self?.toggleTrackpad() }
        root.trackpadPage.onTouchesBegan = { [weak self] in self?.trackpad.touchesBegan($0) }
        root.trackpadPage.onTouchesMoved = { [weak self] in self?.trackpad.touchesMoved($0) }
        root.trackpadPage.onTouchesEnded = { [weak self] in self?.trackpad.touchesEnded($0) }
        root.trackpadPage.onTouchesCancelled = { [weak self] in self?.trackpad.touchesCancelled(atMicros: $0) }
        root.trackpadPage.onTick = { [weak self] in self?.trackpad.tick(nowMicros: $0) }
        trackpad.onChange = { [weak self] in self?.refreshStatus() }
        #if DEBUG
        root.onDebugLongReturn = { [weak self] in self?.sendDebugLongText() }
        root.onDebugLongSpace = { [weak self] in self?.fillDraftToCap() }
        root.onDebugBurst = { [weak self] in self?.toggleBurst() }
        root.onDebugLongStatus = { [weak self] in self?.toggleDictationProbe() }
        root.onMeasureCommand = { [weak self] command in self?.measureCommand(command) }
        peripheral.measurement.onChange = { [weak self] in self?.measurementChanged() }
        restoreDictationProbe()
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
        refreshKeyFeedback()
        refreshStatus()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isOnScreen = true
        KeyboardReadyMarker.markIfReady(hasFullAccess: hasFullAccess)
        refreshTrackpadSettings()
        refreshKeyFeedback()
        refreshDictationSetting()
        #if DEBUG
        dictationAppeared()
        #endif
        updateNavigator()
        syncChineseEngine()
        claimPeripheral()
        refreshStatus()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        reclaimPeripheralIfVacant()
        dictationDidAppear()
        KeyFeedback.activate()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        // Before the peripheral is let go: a held button is released and the Mac is told while the link is still there.
        // A stale controller's late disappear touches nothing shared: not the peripheral's channel, not the key feedback.
        if peripheral.isOwner(lifecycle.token) {
            trackpad.leave()
            KeyFeedback.deactivate()
        } else {
            trackpad.abandon()
        }
        #if DEBUG
        dictationDisappeared()
        #endif
        #if DEBUG
        burst.cancel()
        closeMeasureTouchView()
        #endif
        imeQueue.reset()
        resetQuick()
        chinese.deactivate()
        peripheral.disappear(owner: lifecycle.token)
        showNote(nil)
    }

    /// The host's text or selection changed, so what was committed no longer sits right before the cursor.
    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        chinese.resetHistory()
        dictationWillChange()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        dictationDidChange()
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
        // A channel the previous controller left open is closed; this controller's page opens its own when entered.
        if !trackpad.isActive { peripheral.closePointer() }
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
        peripheral.sendDebugLongText()
    }

    /// TP1: a button of the measurement page. The runs themselves live in `MeasurementRunner`; this only starts them.
    private func measureCommand(_ command: MeasureCommand) {
        let runner = peripheral.measurement
        let config = MeasureLaunchConfig.read()
        switch command {
        case .m2: runner.start(.m2, latency: config.latency)
        case .m3: runner.start(.m3(samples: config.m3Samples), latency: config.latency)
        case .m3Smoke: runner.start(.m3(samples: 200), latency: config.latency)
        case .m5: runner.start(.m5, latency: config.latency)
        case .m6:
            runner.start(
                .m6(MeasurementRunner.Scenario(rawValue: config.m6Scenario) ?? .normal, seconds: config.m6Seconds),
                latency: config.latency)
        case .m7: runner.start(.m7(runs: config.m7Runs), latency: config.latency)
        case .m8: runner.start(.m8(seconds: config.m8Seconds), latency: config.latency)
        case .m4: showMeasureTouchView()
        case .latency:
            peripheral.cycleLatency()
            refreshStatus()
        case .stop: runner.cancel()
        }
    }

    private func showMeasureTouchView() {
        guard measureTouchView == nil, peripheral.isMeasureReady, !peripheral.measurement.isRunning else { return }
        peripheral.measurement.start(.m4, latency: MeasureLaunchConfig.read().latency)
        let surface = MeasurementTouchView(runner: peripheral.measurement)
        surface.onClose = { [weak self] in self?.closeMeasureTouchView() }
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        measureTouchView = surface
    }

    /// The runner's state changed. When the M4 job ended without the surface's × (the connection ended, or the run was
    /// stopped), the surface goes away with it.
    private func measurementChanged() {
        if measureTouchView != nil, peripheral.measurement.job != .m4 { closeMeasureTouchView() }
        refreshStatus()
    }

    private func closeMeasureTouchView() {
        guard let surface = measureTouchView else { return }
        measureTouchView = nil
        surface.removeFromSuperview()
        if peripheral.measurement.job == .m4 { peripheral.measurement.cancel() }
    }

    /// The measurement page of the probe panel: shown only while the Mac says its measurement mode is on.
    private func measurePanelState() -> MeasurePanelState? {
        guard peripheral.latestStatus?.measure == true else { return nil }
        let runner = peripheral.measurement
        return MeasurePanelState(
            enabled: peripheral.isMeasureReady, running: runner.isRunning, text: runner.displayText,
            latencyTitle: peripheral.latencySetting.title)
    }

    /// T15: a four-second press on 換行 starts the burst, and another four-second press stops it. Remote mode only.
    /// Each line goes through `router` like a typed key (instant, empty draft), so the draft and the dictation sync
    /// are not touched.
    private func toggleBurst() {
        reclaimPeripheralIfVacant()
        if burst.isRunning {
            burst.cancel()
            return
        }
        guard mode == .remote, isReady else {
            showNote("Mac 尚未就緒，未輸入")
            return
        }
        showNote("burst 開始")
        burst.start(
            isReady: { [weak self] in self.map { $0.mode == .remote && $0.isReady } ?? false },
            pending: { [weak self] in self?.peripheral.pendingKeyCount ?? Int.max },
            send: { [weak self] n in self?.sendBurstLine(n) ?? false },
            onProgress: { [weak self] sent in self?.showNote("burst \(sent)/\(BurstGenerator.defaultTotal)") },
            onFinish: { [weak self] outcome in self?.showNote(Self.burstNote(outcome)) })
    }

    /// Line `n` is two actions, the same ones a user produces: the text `#n`, then the return key.
    private func sendBurstLine(_ n: Int) -> Bool {
        var scratch = DraftBuffer()
        let before = peripheral.pendingKeyCount
        for action in [KeyAction.character("#\(n)"), .returnKey] {
            let outcome = router.route(action, mode: mode, transmit: .instant, ready: true, draft: &scratch)
            guard outcome == .enqueuedRemote else { return false }
        }
        return peripheral.pendingKeyCount == before + 2
    }

    private static func burstNote(_ outcome: BurstGenerator.Outcome) -> String {
        switch outcome {
        case .finished(let sent): "burst 完成，已送 \(sent) 行"
        case .cancelled(let sent): "burst 已取消，已送 \(sent) 行"
        case .stopped(let sent, let reason):
            switch reason {
            case .notReady: "burst 中止（Mac 未就緒），已送 \(sent) 行"
            case .sendRefused: "burst 中止（送出失敗），已送 \(sent) 行"
            case .stalled: "burst 中止（等不到回覆），已送 \(sent) 行"
            }
        }
    }

    /// T10 step 31 hook: fills the draft with `a` until it holds the cap, so nobody has to tap 1,000 keys. Remote mode
    /// only. The router is told to use the draft (and that the Mac is not ready), so every key lands in the draft and the
    /// enqueue branch is unreachable by construction: nothing here can reach the Mac.
    private func fillDraftToCap() {
        reclaimPeripheralIfVacant()
        guard mode == .remote else { return }
        while draft.text.count < DraftBuffer.maxCharacters {
            let outcome = router.route(.character("a"), mode: mode, transmit: .draft, ready: false, draft: &draft)
            guard outcome == .draftEdited else { break }
        }
        refreshStatus()
    }
    #endif

    // MARK: Dictation sync (D18)

    /// The text around the cursor and the field's identifier. `before` is `nil` while iOS has not loaded the field
    /// (or the field is empty), which is why only a keyboard that has been on screen may treat it as "".
    private var textContext: (before: String?, after: String?, documentId: UUID?) {
        (
            textDocumentProxy.documentContextBeforeInput, textDocumentProxy.documentContextAfterInput,
            documentIdentifier
        )
    }

    /// `documentIdentifier` is declared non-optional (`UUID`) but iOS answers nil in some fields (such as the
    /// container app's own text fields); reading it as a Swift `UUID` traps while bridging, so go through Objective-C.
    /// Second layer: key-value coding throws NSUnknownKeyException when the proxy lacks the getter, so ask first and
    /// answer nil if it does not respond.
    private var documentIdentifier: UUID? {
        let proxy = textDocumentProxy as AnyObject
        guard proxy.responds(to: NSSelectorFromString("documentIdentifier")) else { return nil }
        return proxy.value(forKey: "documentIdentifier") as? UUID
    }

    /// The raw App Group values of 「按鍵聲音」, 「按鍵震動」, 「音量」 and 「震動強度」, read on each `viewWillAppear`. Full
    /// Access is applied when the state is built, so a change of Full Access shows at the next refresh.
    private var storedKeySound: Any?
    private var storedKeyHaptics: Any?
    private var storedKeyVolume: Any?
    private var storedKeyIntensity: Any?
    private var keyFeedback: KeyFeedbackSettings {
        KeyFeedbackSettings(
            storedSound: storedKeySound, storedHaptics: storedKeyHaptics, storedVolume: storedKeyVolume,
            storedIntensity: storedKeyIntensity, hasFullAccess: hasFullAccess)
    }

    private func refreshKeyFeedback() {
        let defaults = UserDefaults(suiteName: AppGroup.identifier)
        storedKeySound = defaults?.object(forKey: AppGroup.Key.keySound)
        storedKeyHaptics = defaults?.object(forKey: AppGroup.Key.keyHaptics)
        storedKeyVolume = defaults?.object(forKey: AppGroup.Key.keySoundVolume)
        storedKeyIntensity = defaults?.object(forKey: AppGroup.Key.keyHapticIntensity)
    }

    private static func storedDictationSetting() -> Any? {
        UserDefaults(suiteName: AppGroup.identifier)?.object(forKey: AppGroup.Key.dictationSync)
    }

    private func refreshDictationSetting() {
        dictationStoredSetting = Self.storedDictationSetting()
        let active = dictationActive
        if active, !dictationWasActive {
            // The sync was off (setting, Local mode) while the keyboard lived: the old snapshot is stale.
            dictationMirror = DictationMirror(counters: dictationMirror.counters)
        }
        dictationWasActive = active
    }

    /// Takes the baseline the user just caused (switching to Remote, turning the panel on) while the keyboard is on
    /// screen. A `nil` text before the cursor then means an empty field. The appearance paths never do this.
    private func rebaselineDictationFromVisibleKeyboard() {
        let context = textContext
        dictationMirror.rebaseline(
            before: context.before ?? "", after: context.after, documentId: context.documentId)
    }

    /// The panel's numbers changed: save and redraw them. Release builds have no panel.
    private func dictationCountersChanged() {
        #if DEBUG
        guard dictationProbeOn else { return }
        persistDictationProbe()
        refreshStatus()
        #endif
    }

    /// The field is about to change. A keyboard without a baseline takes one from the text as it is now (before the
    /// change), so the very first dictated sentence is not swallowed as "the baseline".
    private func dictationWillChange() {
        guard dictationActive else { return }
        dictationMirror.noteWillChange()
        if !dictationMirror.hasBaseline {
            let context = textContext
            let initial = DictationMirror.initialBaselineText(
                before: context.before, hasText: textDocumentProxy.hasText, phase: .willChange)
            if dictationMirror.rebaseline(before: initial, after: context.after, documentId: context.documentId) {
                Self.dictationLog.info("textWillChange outcome=baselineTaken")
            }
        }
        dictationCountersChanged()
    }

    /// Compares the field with the last snapshot. A difference goes through the same router as typed keys: to the Mac
    /// when the instant path applies, into the draft when the draft rules say so. Only lengths and counts are logged,
    /// never text.
    private func dictationDidChange() {
        guard dictationActive else { return }
        let context = textContext
        let before: String
        if dictationMirror.hasBaseline {
            before = context.before ?? ""
        } else if let initial = DictationMirror.initialBaselineText(
            before: context.before, hasText: textDocumentProxy.hasText, phase: .didChangeOrAppear) {
            before = initial
        } else {
            // No baseline and no text yet: the field is probably not loaded, and "" would make the next change look
            // like the whole existing text. Wait for a change that carries text.
            dictationMirror.noteDidChange()
            Self.dictationLog.info("textDidChange outcome=baselineSkippedNil did=\(self.dictationMirror.counters.didChangeCalls)")
            dictationCountersChanged()
            return
        }
        let outcome = dictationMirror.observe(
            before: before, after: context.after ?? "", documentId: context.documentId,
            at: ProcessInfo.processInfo.systemUptime)
        finishDictationObservation(outcome, event: "textDidChange")
    }

    /// The keyboard finished appearing. With a baseline it compares once, so a change made while the view was hidden is
    /// still found; the log names it `appearDiff` so it can be told from a `textDidChange`. Without a baseline it takes
    /// one when the field says what it holds, and otherwise waits for a change.
    private func dictationDidAppear() {
        guard dictationActive else { return }
        let context = textContext
        guard dictationMirror.hasBaseline else {
            let initial = DictationMirror.initialBaselineText(
                before: context.before, hasText: textDocumentProxy.hasText, phase: .didChangeOrAppear)
            let taken = dictationMirror.rebaseline(
                before: initial, after: context.after, documentId: context.documentId)
            Self.dictationLog.info("appear outcome=\(taken ? "baselineTaken" : "appearSkippedNil", privacy: .public)")
            return
        }
        // A `nil` text before the cursor may be a field that is not loaded yet; comparing it as "" could send
        // backspaces for text that was never deleted. Skip, and leave the baseline for the next `textDidChange`.
        guard let outcome = dictationMirror.observeOnAppear(
            before: context.before, after: context.after, documentId: context.documentId,
            at: ProcessInfo.processInfo.systemUptime)
        else {
            if context.before == nil { Self.dictationLog.info("appear outcome=appearSkippedNil") }
            return
        }
        finishDictationObservation(outcome, event: "appear")
    }

    private func finishDictationObservation(_ outcome: DictationMirror.Outcome, event: String) {
        var name = "other"
        switch outcome {
        case .baselineSet: name = "baselineSet"
        case .unchanged: name = "unchanged"
        case .cursorMoved: name = "cursorMoved"
        case .ownEdit: name = "ownEdit"
        case .tooLarge:
            name = "tooLarge"
            showNote("差分過大，已重設")
        case .documentChanged:
            name = "documentChanged"
            showNote("換了欄位，已重設")
        case .untrusted:
            name = "untrusted"
            showNote("文字窗口不可信，已重設")
        case .events(let events):
            name = event == "appear" ? "appearDiff" : "events"
            syncDictation(events)
        }
        let counters = dictationMirror.counters
        Self.dictationLog.info(
            "\(event, privacy: .public) outcome=\(name, privacy: .public) backspaces=\(counters.lastBackspaces) characters=\(counters.lastCharacters) did=\(counters.didChangeCalls) growths=\(counters.externalGrowths) untrusted=\(counters.untrusted) docChanges=\(counters.documentChanges) skipped=\(counters.draftSkipped)")
        dictationCountersChanged()
    }

    private func syncDictation(_ events: [EventKind]) {
        // A password field takes no text, and a difference that deleted draft text without typing the new text would
        // leave a hole, so the whole difference is dropped. The status line already says why.
        if DictationSync.isDropped(events: events, blocked: isBlocked) {
            Self.dictationLog.info("sync outcome=blocked")
            return
        }
        // A difference with backspaces goes into the draft only when the draft cursor sits right behind the text it
        // deletes; if the user moved the cursor away or edited the draft since, the whole difference (its new text
        // too) is dropped, so nothing unrelated is deleted and nothing is doubled. Straight to the Mac is not checked.
        if events.contains(.backspace),
            DictationSync.goesToDraft(transmit: transmit, draftEmpty: draft.isEmpty),
            !DictationSync.draftAccepts(deleted: dictationMirror.lastDeleted, draft: draft) {
            dictationMirror.noteDraftSkipped()
            Self.dictationLog.info("sync outcome=draftSkipped")
            showNote("草稿已改動，這次聽寫修正未套用")
            return
        }
        isSyncingDictation = true
        defer { isSyncingDictation = false }
        var drafted = 0
        for event in events {
            let action: KeyAction
            switch event {
            case .text(let text): action = .character(text)
            case .backspace: action = .backspace
            default: continue
            }
            let outcome = router.route(action, mode: mode, transmit: transmit, ready: isReady, draft: &draft, blocked: isBlocked)
            switch outcome {
            case .draftEdited: drafted += 1
            case .draftFull:
                showNote("草稿已滿，聽寫差分未同步")
            case .rejected:
                // Dropped, not drafted and not sent: the Mac has nowhere to type it. Every later key of this difference
                // would be dropped the same way, so stop and say so once.
                if let text = StatusLine.droppedKeyNote(link: peripheral.linkState, receiver: peripheral.latestStatus) { showNote(text) }
            default: break
            }
            if outcome == .draftFull || outcome == .rejected { break }
        }
        if drafted > 0 {
            dictationMirror.noteDrafted(drafted)
            refreshStatus()
        }
    }

    #if DEBUG
    // MARK: Debug checklist panel

    private func restoreDictationProbe() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.dictationOnKey) else { return }
        let startedAt = defaults.object(forKey: Self.dictationOnAtKey) as? Double
        guard DictationMirror.isLeaseValid(startedAt: startedAt, now: Date().timeIntervalSince1970) else {
            // Switched on too long ago (or without a start time): a forgotten panel stays off.
            defaults.set(false, forKey: Self.dictationOnKey)
            defaults.removeObject(forKey: Self.dictationOnAtKey)
            Self.dictationLog.info("probe lease expired")
            return
        }
        dictationProbeOn = true
        let counters = defaults.data(forKey: Self.dictationCountersKey)
            .flatMap { try? JSONDecoder().decode(DictationMirror.Counters.self, from: $0) }
        dictationMirror = DictationMirror(counters: counters ?? DictationMirror.Counters())
    }

    private func persistDictationProbe() {
        let defaults = UserDefaults.standard
        defaults.set(dictationProbeOn, forKey: Self.dictationOnKey)
        if let data = try? JSONEncoder().encode(dictationMirror.counters) {
            defaults.set(data, forKey: Self.dictationCountersKey)
        }
    }

    /// A 2-second press on the status label. Turning on needs Remote mode; turning off works anywhere. The panel only
    /// shows counts: the sync runs with or without it.
    private func toggleDictationProbe() {
        if dictationProbeOn {
            dictationProbeOn = false
            dictationSentIds = []
            UserDefaults.standard.removeObject(forKey: Self.dictationOnAtKey)
            persistDictationProbe()
            Self.dictationLog.info("probe off")
            showNote("檢查面板已關閉")
            return
        }
        guard mode == .remote else {
            showNote("檢查面板需在遠端模式開啟")
            return
        }
        dictationProbeOn = true
        dictationMirror = DictationMirror()
        dictationSentIds = []
        if dictationActive { rebaselineDictationFromVisibleKeyboard() }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.dictationOnAtKey)
        persistDictationProbe()
        Self.dictationLog.info("probe on")
        showNote(dictationActive ? "檢查面板已開啟" : "檢查面板已開啟（App 已關閉聽寫同步）")
    }

    private func dictationAppeared() {
        guard dictationProbeOn else { return }
        dictationMirror.noteAppeared()
        persistDictationProbe()
        Self.dictationLog.info("keyboard appeared count=\(self.dictationMirror.counters.appearances)")
    }

    private func dictationDisappeared() {
        guard dictationProbeOn else { return }
        dictationMirror.noteDisappeared()
        persistDictationProbe()
        Self.dictationLog.info("keyboard disappeared count=\(self.dictationMirror.counters.disappearances)")
    }

    private func dictationSent(_ id: UUID) {
        guard dictationProbeOn, isSyncingDictation else { return }
        dictationSentIds.insert(id)
        dictationMirror.noteSent(1)
    }

    private func dictationAcked(_ id: UUID) {
        guard dictationProbeOn, dictationSentIds.remove(id) != nil else { return }
        dictationMirror.noteAcked()
        persistDictationProbe()
        Self.dictationLog.info("ack received sent=\(self.dictationMirror.counters.eventsSent) acked=\(self.dictationMirror.counters.eventsAcked)")
        refreshStatus()
    }

    /// The checklist, one item per line. Item 1 is the user's own eyes; items 2 to 5 are measurements.
    private func dictationProbeLines() -> [String]? {
        guard dictationProbeOn else { return nil }
        let c = dictationMirror.counters
        var diff = "④ 差分  退 \(c.lastBackspaces) 字 \(c.lastCharacters)"
        if c.resets > 0 { diff += "  過大 \(c.resets)" }
        if c.untrusted > 0 { diff += "  截斷 \(c.untrusted)" }
        if c.documentChanges > 0 { diff += "  換檔 \(c.documentChanges)" }
        if c.draftSkipped > 0 { diff += "  略過 \(c.draftSkipped)" }
        var mac = "⑤ Mac  送 \(c.eventsSent) 回 \(c.eventsAcked)"
        if c.eventsDrafted > 0 { mac += " 稿 \(c.eventsDrafted)" }
        return [
            "① 麥克風  請目視確認下方有麥克風",
            "② 寫入欄位  \(c.externalGrowths > 0 ? "是" : "否") \(c.externalGrowths)",
            "③ 鍵盤收到變化  did \(c.didChangeCalls)  will \(c.willChangeCalls)  隱 \(c.disappearances)  基準 \(c.baselines)",
            diff,
            mac
        ]
    }
    #endif

    // MARK: Pages

    /// Starts from the saved letter page; the field type may override it (email and URL open English, numbers open symbols).
    private func updateNavigator() {
        let last = KeyboardPage.stored(rawValue: UserDefaults.standard.string(forKey: Self.pageDefaultsKey))
        activeChineseMethod = chineseMethod
        navigator = PageNavigator(lastPage: last, field: fieldKind(), chineseAvailable: activeChineseMethod != nil)
    }

    /// The Chinese method in use: the host App's choice, if this build has it and Full Access allows it.
    private var chineseMethod: ChineseInputMethodID? {
        let saved = ChineseInputMethodID.stored(
            rawValue: UserDefaults(suiteName: AppGroup.identifier)?.string(forKey: AppGroup.Key.chineseMethod))
        return ChineseMethodResolver.effective(
            saved: saved, hasFullAccess: hasFullAccess, handwritingNeedsFullAccess: Self.handwritingNeedsFullAccess,
            installed: Self.installedMethods)
    }

    /// Loads the engine of the Chinese method in use while the Chinese page is showing; leaving the page drops ink,
    /// the input code and candidates.
    private func syncChineseEngine() {
        guard navigator.page == .chinese else {
            chinese.resetComposition()
            resetQuick()
            return
        }
        if activeChineseMethod == .quick {
            loadQuickIfNeeded()
        } else {
            chinese.activate()
        }
    }

    private func loadQuickIfNeeded() {
        guard quick == nil else { return }
        guard
            let url = Bundle(for: KeyboardViewController.self).url(forResource: "quick-table", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8),
            let dictionary = try? QuickDictionary(tableText: text)
        else {
            showNote("速成字碼表無法載入")
            return
        }
        quick = QuickInputMethod(dictionary: dictionary)
    }

    private func resetQuick() {
        quick?.reset()
        quickOutput = IMEOutput()
    }

    private func fieldKind() -> FieldKind {
        switch textDocumentProxy.keyboardType ?? .default {
        case .emailAddress, .URL, .webSearch: .emailOrURL
        case .numberPad, .decimalPad, .numbersAndPunctuation, .asciiCapableNumberPad: .number
        default: .text
        }
    }

    // MARK: Touchpad

    /// Reads 「靈敏度」 (App Group, set in the host App) and 「傳輸次數」 whenever the keyboard appears or the pad is entered.
    /// The sensitivity the page used to keep in the extension's own defaults is moved over once.
    private func refreshTrackpadSettings() {
        let group = UserDefaults(suiteName: AppGroup.identifier)
        let standard = UserDefaults.standard
        let sensitivity = TrackpadSensitivity.resolved(
            appGroup: group?.object(forKey: AppGroup.Key.trackpadSensitivity),
            legacy: standard.object(forKey: TrackpadSensitivity.legacyDefaultsKey))
        if sensitivity.migrated, let group {
            group.set(sensitivity.value, forKey: AppGroup.Key.trackpadSensitivity)
            standard.removeObject(forKey: TrackpadSensitivity.legacyDefaultsKey)
        }
        trackpad.sensitivity = sensitivity.value
        // Without Full Access the App Group may not be writable; the extension's own defaults then keep the rate.
        let rate = TrackpadSendRate.clamped(
            group?.object(forKey: AppGroup.Key.trackpadSendRate) ?? standard.object(forKey: AppGroup.Key.trackpadSendRate))
        trackpad.sendRate = rate
        rootView?.trackpadPage.setSendRate(rate)
    }

    private func toggleTrackpad() {
        reclaimPeripheralIfVacant()
        if trackpad.isActive {
            trackpad.leave()
        } else if mode == .remote, peripheral.linkState == .connected {
            refreshTrackpadSettings()
            trackpad.enter()
        }
    }

    // MARK: Keys

    /// Returns whether the key was taken: `false` when the draft was full or the key was refused.
    @discardableResult
    private func perform(_ action: KeyAction) -> Bool {
        reclaimPeripheralIfVacant()
        if navigator.page == .chinese, let input = Self.imeInput(for: action) {
            enqueueIME(input)
            return true
        }
        // While an input-method key is still pending, every key waits behind it (symbols, cursor keys, 傳送, the
        // toggles, 中英), so nothing overtakes a commit that has not happened yet.
        if imeQueue.isBusy {
            imeQueue.enqueue { [weak self] _ in self?.route(action) }
            return true
        }
        return route(action)
    }

    /// The keys the Chinese page hands to the input method first; the others are never its business.
    private static func imeInput(for action: KeyAction) -> IMEInput? {
        switch action {
        case .space: .space
        case .backspace: .backspace
        case .returnKey: .returnKey
        default: nil
        }
    }

    private func enqueueIME(_ input: IMEInput) {
        imeQueue.enqueue { [weak self] run in await self?.performIME(input, run: run) }
    }

    /// Feeds the input method, then routes what it commits or passes through like typed keys. A queue reset while the
    /// input method was waiting (the keyboard went away) drops the result.
    private func performIME(_ input: IMEInput, run: OrderedActionQueue.Run) async {
        reclaimPeripheralIfVacant()
        let output: IMEOutput
        if activeChineseMethod == .quick {
            loadQuickIfNeeded()
            output = quick?.handle(input) ?? IMEOutput(passThrough: Self.fallbackKey(for: input))
            quickOutput = IMEOutput(composing: output.composing, candidates: output.candidates, shift: output.shift)
            refreshStatus()
        } else {
            output = await chinese.session.handle(input)
        }
        guard run.isCurrent else { return }
        if let text = output.commit { route(.character(text)) }
        if let key = output.passThrough { route(key) }
    }

    /// What a key does when the Quick table could not be loaded: it types like a key of the English page.
    private static func fallbackKey(for input: IMEInput) -> KeyAction? {
        switch input {
        case .space: .space
        case .backspace: .backspace
        case .returnKey: .returnKey
        case .key(let text): .character(text)
        default: nil
        }
    }

    @discardableResult
    private func route(_ action: KeyAction) -> Bool {
        let outcome = router.route(action, mode: mode, transmit: transmit, ready: isReady, draft: &draft, blocked: isBlocked)
        handle(outcome, for: action)
        return outcome != .draftFull && outcome != .rejected
    }

    private func handle(_ outcome: RouteOutcome, for action: KeyAction) {
        switch outcome {
        case .modeToggled(let requested):
            // Persist what actually took effect, so a refused Remote (no Full Access) is not remembered as Remote.
            let applied = ModeResolver.effectiveMode(saved: requested, hasFullAccess: hasFullAccess)
            savedMode = applied
            chinese.resetHistory()
            if applied == .remote, DictationSync.isEnabled(stored: dictationStoredSetting) {
                rebaselineDictationFromVisibleKeyboard()
            }
            dictationWasActive = dictationActive
            UserDefaults.standard.set(applied.rawValue, forKey: Self.modeDefaultsKey)
            showNote(requested == .remote && applied == .local ? "遠端需要開啟「允許完整取用」" : nil)
        case .transmitToggled(let requested):
            transmit = requested
            UserDefaults.standard.set(requested.rawValue, forKey: Self.transmitDefaultsKey)
            refreshStatus()
        case .pageChanged:
            if action == .switchSymbols { navigator.switchSymbols() } else { navigator.switchChineseEnglish() }
            UserDefaults.standard.set(navigator.persistablePage.storageValue, forKey: Self.pageDefaultsKey)
            syncChineseEngine()
            refreshStatus()
        case .draftFull:
            showNote("草稿已達 1,000 字上限")
        case .rejected:
            // A draft key pressed in Local mode does nothing and says nothing; so does 傳送 on an empty draft
            // while the Mac is ready (the button is grey then anyway). A key dropped because the Mac is not ready says
            // why, unless the status line already does (a password field, a Mac without Accessibility).
            if mode == .remote, !isReady,
                let text = StatusLine.droppedKeyNote(link: peripheral.linkState, receiver: peripheral.latestStatus) {
                showNote(text)
            }
        case .draftEdited, .draftSent:
            refreshStatus()
        case .dismissKeyboard:
            dismissKeyboard()
        case .insertedLocally, .enqueuedRemote, .advanceInputMode:
            break
        }
    }

    private func received(_ message: ControlMessage) {
        // A probe's answer has no wording, so it leaves the status line alone.
        if case .ack(let ack) = message, let text = StatusLine.ackText(ack.result) { showNote(text) }
        #if DEBUG
        if case .ack(let ack) = message { dictationAcked(ack.eventId) }
        #endif
        refreshStatus()
    }

    // MARK: View state

    private func refreshStatus() {
        guard let rootView else { return }
        // The page only exists in Remote mode; and after a reconnect it asks the Mac to open the channel again.
        if trackpad.isActive, mode != .remote { trackpad.leave() }
        trackpad.refresh()
        let link = peripheral.linkState
        let isQuick = activeChineseMethod == .quick
        let line = StatusLine.text(
            mode: mode, link: link, receiver: peripheral.latestStatus, connectedMs: peripheral.reconnectLatencyMs,
            paired: peripheral.isPaired)
        let display = StatusLine.display(
            mode: mode, link: link, receiver: peripheral.latestStatus, paired: peripheral.isPaired, note: note)
        let built = KeyboardViewState(
            mode: mode,
            transmit: transmit,
            page: navigator.page,
            top: TopAreaState(
                mode: mode, transmit: transmit, ready: isReady, draftEmpty: draft.isEmpty, hasNote: display != nil,
                showsCandidates: navigator.page == .chinese && isQuick),
            draft: draft,
            status: display,
            statusDetail: StatusLine.appendingNote(line, note: note),
            linkName: link.name,
            showsGlobe: needsInputModeSwitchKey,
            chineseAvailable: navigator.chineseAvailable,
            candidates: navigator.page == .chinese ? (isQuick ? quickOutput.candidates : chinese.candidates) : [],
            chineseMethod: activeChineseMethod ?? .handwriting,
            composing: navigator.page == .chinese && isQuick ? quickOutput.composing : "",
            quickShift: navigator.page == .chinese && isQuick && quickOutput.shift,
            handwritingMessage: navigator.page == .chinese && !isQuick ? Self.message(for: chinese.modelStatus) : nil,
            hapticsEnabled: keyFeedback.haptics, soundEnabled: keyFeedback.sound,
            soundVolume: keyFeedback.soundVolume, customSound: keyFeedback.customSound,
            hapticIntensity: keyFeedback.hapticIntensity,
            trackpadAvailable: mode == .remote && link == .connected,
            trackpad: trackpad.isActive ? TrackpadPageState(message: trackpad.message) : nil)
        #if DEBUG
        var state = built
        state.dictationProbeLines = dictationProbeLines()
        state.measurePanel = measurePanelState()
        #else
        let state = built
        #endif
        rootView.apply(state)
        let height = rootView.preferredHeight
        if heightConstraint?.constant != height { heightConstraint?.constant = height }
    }

    private static func message(for status: ChineseInputCoordinator.ModelStatus) -> String? {
        switch status {
        case .idle, .ready: nil
        case .importing: "正在匯入手寫模型…"
        case .missing: "請先在 App 下載手寫模型"
        case .importFailed: "手寫模型匯入失敗，請到 App 重新下載"
        }
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
}
