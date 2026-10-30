import UIKit
import RemoteKeyboardCore
#if DEBUG
import os
#endif

/// Adapts the system text proxy to the Core `TextSink` protocol.
@MainActor
struct TextDocumentProxySink: @preconcurrency TextSink {
    let proxy: UITextDocumentProxy
    func insertText(_ text: String) { proxy.insertText(text) }
    func deleteBackward() { proxy.deleteBackward() }
}

#if DEBUG
/// T13: wraps the text proxy sink so the dictation probe knows a change in the field is ours (Local mode keys).
@MainActor
struct ProbingTextSink: @preconcurrency TextSink {
    let base: TextDocumentProxySink
    let onOwnEdit: () -> Void
    func insertText(_ text: String) {
        onOwnEdit()
        base.insertText(text)
        onOwnEdit()
    }
    func deleteBackward() {
        onOwnEdit()
        base.deleteBackward()
        onOwnEdit()
    }
}

/// T13: forwards to the peripheral and reports the id of each event it sent, so acks can be matched to them.
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
    /// The Chinese methods this build contains. Quick (速成) arrives in T12b.
    private static let installedMethods: Set<ChineseInputMethodID> = [.handwriting]
    /// ML Kit's model is moved through the App Group, which needs Full Access.
    private static let handwritingNeedsFullAccess = true

    private var rootView: KeyboardRootView?
    private var heightConstraint: NSLayoutConstraint?
    private let peripheral = KeyboardBLEPeripheral.shared
    /// Counts this controller and releases peripheral ownership when it is deallocated.
    private let lifecycle = ControllerLifecycle()
    #if DEBUG
    private lazy var router = InputRouter(
        local: ProbingTextSink(
            base: TextDocumentProxySink(proxy: textDocumentProxy), onOwnEdit: { [weak self] in self?.dictationOwnEdit() }),
        remote: ProbingRemoteSink(peripheral: peripheral, onSent: { [weak self] id in self?.dictationSent(id) }))
    #else
    private lazy var router = InputRouter(local: TextDocumentProxySink(proxy: textDocumentProxy), remote: peripheral)
    #endif
    private var savedMode: KeyboardMode = .local
    private var transmit: TransmitMode = .instant
    private var navigator = PageNavigator(lastPage: nil, field: .text, chineseAvailable: false)
    private let chinese = ChineseInputCoordinator()
    /// Keys that wait behind an input-method key (a space that waits for a recognition) run in order through this.
    private let imeQueue = OrderedActionQueue()
    /// Text typed in Remote mode and not sent yet. Memory only: it dies with this controller and is never written out.
    private var draft = DraftBuffer()
    /// A short-lived line shown after the status, such as the last ack. Cleared by `noteTask`.
    private var note: String?
    private var noteTask: Task<Void, Never>?
    /// Between `viewWillAppear` and `viewDidDisappear`; only a controller on screen may reclaim the peripheral.
    private var isOnScreen = false
    #if DEBUG
    // T13 dictation probe (DEBUG builds only). Memory holds the text snapshot; UserDefaults holds only the on flag and
    // the counters, so a keyboard that iOS rebuilds during dictation still shows the numbers.
    private static let dictationOnKey = "rk.dictationProbeOn"
    /// Wall-clock time the switch was turned on; the switch is only restored for `DictationMirror.leaseSeconds`.
    private static let dictationOnAtKey = "rk.dictationProbeOnAt"
    private static let dictationCountersKey = "rk.dictationProbeCounters"
    private static let dictationLog = Logger(subsystem: "com.ansonhui.remotekeyboard", category: "dictation")
    private var dictationProbeOn = false
    private var dictationMirror = DictationMirror()
    private var dictationSentIds: Set<UUID> = []
    /// True while the probe routes a diff, so only those events count for checklist item 5.
    private var isSyncingDictation = false
    #endif

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
        root.onStrokeBegan = { [weak self] in self?.chinese.session.strokeBegan() }
        root.onStrokesEnded = { [weak self] strokes, size in self?.chinese.session.strokesEnded(strokes, size: size) }
        root.onSelectCandidate = { [weak self] index in self?.enqueueIME(.selectCandidate(index)) }
        root.onClearInk = { [weak self] in self?.enqueueIME(.clear) }
        chinese.onChange = { [weak self] in self?.refreshStatus() }
        chinese.onClearInk = { [weak self] in self?.rootView?.clearInk() }
        #if DEBUG
        root.onDebugLongReturn = { [weak self] in self?.sendDebugLongText() }
        root.onDebugLongSpace = { [weak self] in self?.fillDraftToCap() }
        root.onDebugLongStatus = { [weak self] in self?.toggleDictationProbe() }
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
        refreshStatus()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isOnScreen = true
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
        #if DEBUG
        dictationDidAppear()
        #endif
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        isOnScreen = false
        #if DEBUG
        dictationDisappeared()
        #endif
        imeQueue.reset()
        chinese.deactivate()
        peripheral.disappear(owner: lifecycle.token)
        showNote(nil)
    }

    /// The host's text or selection changed, so what was committed no longer sits right before the cursor.
    override func textWillChange(_ textInput: UITextInput?) {
        super.textWillChange(textInput)
        chinese.resetHistory()
        #if DEBUG
        dictationWillChange()
        #endif
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        #if DEBUG
        dictationDidChange()
        #endif
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

    /// T10 step 31 hook: fills the draft with `a` until it holds the cap, so nobody has to tap 1,000 keys. Remote mode
    /// only. The router is told the Mac is not ready, so every key lands in the draft and the enqueue branch is
    /// unreachable by construction: nothing here can reach the Mac.
    private func fillDraftToCap() {
        reclaimPeripheralIfVacant()
        guard mode == .remote else { return }
        while draft.text.count < DraftBuffer.maxCharacters {
            let outcome = router.route(.character("a"), mode: mode, transmit: transmit, ready: false, draft: &draft)
            guard outcome == .draftEdited else { break }
        }
        refreshStatus()
    }
    #endif

    // MARK: T13 dictation probe (DEBUG)

    #if DEBUG
    /// The text around the cursor and the field's identifier. `before` is `nil` while iOS has not loaded the field
    /// (or the cursor is at the very start), which is why only a keyboard that has been on screen may treat it as "".
    private var textContext: (before: String?, after: String?, documentId: UUID?) {
        (
            textDocumentProxy.documentContextBeforeInput, textDocumentProxy.documentContextAfterInput,
            textDocumentProxy.documentIdentifier
        )
    }

    private func restoreDictationProbe() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Self.dictationOnKey) else { return }
        let startedAt = defaults.object(forKey: Self.dictationOnAtKey) as? Double
        guard DictationMirror.isLeaseValid(startedAt: startedAt, now: Date().timeIntervalSince1970) else {
            // Switched on too long ago (or without a start time): a forgotten switch stays off.
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

    /// Takes the baseline the user just caused (switching the probe on, changing mode) while the keyboard is on
    /// screen. A `nil` text before the cursor then means an empty field. The appearance paths never do this.
    private func rebaselineDictationFromVisibleKeyboard() {
        let context = textContext
        dictationMirror.rebaseline(
            before: context.before ?? "", after: context.after, documentId: context.documentId)
    }

    /// A 2-second press on the status label. Turning on needs Remote mode; turning off works anywhere.
    private func toggleDictationProbe() {
        if dictationProbeOn {
            dictationProbeOn = false
            dictationSentIds = []
            UserDefaults.standard.removeObject(forKey: Self.dictationOnAtKey)
            persistDictationProbe()
            Self.dictationLog.info("probe off")
            showNote("聽寫探測已關閉")
            return
        }
        guard mode == .remote else {
            showNote("聽寫探測需在遠端模式開啟")
            return
        }
        dictationProbeOn = true
        dictationMirror = DictationMirror()
        dictationSentIds = []
        rebaselineDictationFromVisibleKeyboard()
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.dictationOnAtKey)
        persistDictationProbe()
        Self.dictationLog.info("probe on")
        showNote("聽寫探測已開啟")
    }

    /// The keyboard view is about to appear. No baseline is taken here: the field may not be loaded yet, and a baseline
    /// of "" would send the whole existing text at the first change. A keyboard without a baseline gets one from its
    /// first `textDidChange`.
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

    private func dictationWillChange() {
        guard dictationProbeOn else { return }
        dictationMirror.noteWillChange()
        persistDictationProbe()
        Self.dictationLog.info("textWillChange count=\(self.dictationMirror.counters.willChangeCalls)")
        refreshStatus()
    }

    /// Our own `insertText` / `deleteBackward` (Local mode): the field changes, but dictation did not write it.
    private func dictationOwnEdit() {
        guard dictationProbeOn else { return }
        dictationMirror.noteOwnEdit(at: ProcessInfo.processInfo.systemUptime)
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

    /// Compares the field with the last snapshot. In Remote mode a difference goes through the same router as typed
    /// keys: to the Mac when the instant path applies, into the draft when the draft rules say so. In Local mode the
    /// probe only observes. Only lengths and counts are logged, never text.
    private func dictationDidChange() {
        guard dictationProbeOn else { return }
        let context = textContext
        // No baseline and no text yet: the field is probably not loaded, and "" would make the next change look like
        // the whole existing text. Wait for a change that carries text.
        if !dictationMirror.hasBaseline, context.before == nil {
            dictationMirror.noteDidChange()
            Self.dictationLog.info("textDidChange outcome=baselineSkippedNil did=\(self.dictationMirror.counters.didChangeCalls)")
            persistDictationProbe()
            refreshStatus()
            return
        }
        let outcome = dictationMirror.observe(
            before: context.before ?? "", after: context.after ?? "", documentId: context.documentId,
            at: ProcessInfo.processInfo.systemUptime)
        finishDictationObservation(outcome, event: "textDidChange")
    }

    /// The keyboard finished appearing. With a baseline it compares once, so a change made while the view was hidden is
    /// still found; the log names it `appearDiff` so it can be told from a `textDidChange`. Without a baseline it waits
    /// for the first `textDidChange`.
    private func dictationDidAppear() {
        guard dictationProbeOn, dictationMirror.hasBaseline else { return }
        let context = textContext
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
            name = mode == .remote ? "events" : "eventsObservedOnly"
            if event == "appear" { name = "appearDiff" }
            if mode == .remote { syncDictation(events) }
        }
        let counters = dictationMirror.counters
        Self.dictationLog.info(
            "\(event, privacy: .public) outcome=\(name, privacy: .public) backspaces=\(counters.lastBackspaces) characters=\(counters.lastCharacters) did=\(counters.didChangeCalls) growths=\(counters.externalGrowths) untrusted=\(counters.untrusted) docChanges=\(counters.documentChanges)")
        persistDictationProbe()
        refreshStatus()
    }

    private func syncDictation(_ events: [EventKind]) {
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
            let outcome = router.route(action, mode: mode, transmit: transmit, ready: isReady, draft: &draft)
            switch outcome {
            case .draftEdited: drafted += 1
            case .draftFull:
                showNote("草稿已滿，聽寫差分未同步")
            default: break
            }
            if outcome == .draftFull { break }
        }
        if drafted > 0 { dictationMirror.noteDrafted(drafted) }
    }

    /// The checklist, one item per line. Item 1 is the user's own eyes; items 2 to 5 are measurements.
    private func dictationProbeLines() -> [String]? {
        guard dictationProbeOn else { return nil }
        let c = dictationMirror.counters
        var diff = "④ 差分  退 \(c.lastBackspaces) 字 \(c.lastCharacters)"
        if c.resets > 0 { diff += "  過大 \(c.resets)" }
        if c.untrusted > 0 { diff += "  截斷 \(c.untrusted)" }
        if c.documentChanges > 0 { diff += "  換檔 \(c.documentChanges)" }
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
        navigator = PageNavigator(lastPage: last, field: fieldKind(), chineseAvailable: chineseMethod != nil)
    }

    /// The Chinese method in use: the host App's choice, if this build has it and Full Access allows it.
    private var chineseMethod: ChineseInputMethodID? {
        let saved = ChineseInputMethodID.stored(
            rawValue: UserDefaults(suiteName: AppGroup.identifier)?.string(forKey: AppGroup.Key.chineseMethod))
        return ChineseMethodResolver.effective(
            saved: saved, hasFullAccess: hasFullAccess, handwritingNeedsFullAccess: Self.handwritingNeedsFullAccess,
            installed: Self.installedMethods)
    }

    /// Loads the handwriting engine while the Chinese page is showing; leaving the page drops ink and candidates.
    private func syncChineseEngine() {
        if navigator.page == .chinese {
            chinese.activate()
        } else {
            chinese.resetComposition()
        }
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
        let output = await chinese.session.handle(input)
        guard run.isCurrent else { return }
        if let text = output.commit { route(.character(text)) }
        if let key = output.passThrough { route(key) }
    }

    @discardableResult
    private func route(_ action: KeyAction) -> Bool {
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
            chinese.resetHistory()
            #if DEBUG
            if dictationProbeOn { rebaselineDictationFromVisibleKeyboard() }
            #endif
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
        #if DEBUG
        if case .ack(let ack) = message { dictationAcked(ack.eventId) }
        #endif
        refreshStatus()
    }

    // MARK: View state

    private func refreshStatus() {
        guard let rootView else { return }
        let link = peripheral.linkState
        let line = StatusLine.text(
            mode: mode, link: link, receiver: peripheral.latestStatus, connectedMs: peripheral.reconnectLatencyMs,
            paired: peripheral.isPaired)
        let built = KeyboardViewState(
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
            chineseAvailable: navigator.chineseAvailable,
            candidates: navigator.page == .chinese ? chinese.candidates : [],
            handwritingMessage: navigator.page == .chinese ? Self.message(for: chinese.modelStatus) : nil,
            hapticsEnabled: hasFullAccess)
        #if DEBUG
        var state = built
        state.dictationProbeLines = dictationProbeLines()
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

    private static func probeStatusText() -> String {
        let value = UserDefaults(suiteName: AppGroup.identifier)?.object(forKey: AppGroup.Key.probe)
        let group = value == nil ? "AppGroup: NIL" : "AppGroup: OK"
        return "\(group)  版本 \(BuildStamp.current())"
    }
}
