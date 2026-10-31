import RemoteKeyboardCore
import UIKit

/// Everything the keyboard view needs to draw itself. The controller builds one from its state; the host app's
/// debug preview builds one from fake values. The views never see the peripheral or the text proxy.
struct KeyboardViewState: Equatable {
    var mode: KeyboardMode
    var transmit: TransmitMode
    var page: KeyboardPage
    var top: TopAreaState
    var draft: DraftBuffer
    var statusText: String
    /// The BLE link state name, exposed as the accessibility value of `rk.status`.
    var linkName: String
    var probeText: String
    var showsGlobe: Bool
    var chineseAvailable: Bool
    /// Handwriting candidates for the candidate row; empty outside the Chinese page.
    var candidates: [String] = []
    /// The Chinese method behind the Chinese page (handwriting draws the writing area, Quick the radical keys).
    var chineseMethod: ChineseInputMethodID = .handwriting
    /// Quick: the input code as radicals, drawn before the candidates.
    var composing: String = ""
    /// Quick: a one-shot Shift is waiting; the input method's state, so the key follows it.
    var quickShift: Bool = false
    /// Shown over the writing area instead of letting the user write (the model is missing or still importing).
    var handwritingMessage: String?
    /// Light haptic on every key at touch down. True only when the keyboard has Full Access; the preview passes false.
    var hapticsEnabled: Bool
    #if DEBUG
    /// T13 dictation probe checklist (five lines, one item each), drawn over the English page's letter rows; nil when
    /// the probe is off.
    var dictationProbeLines: [String]?
    #endif
}

/// The whole keyboard: top area, key rows and bottom row. It reports every key as a `KeyAction`.
final class KeyboardRootView: UIView {
    /// Returns whether the key was taken; a refused key (full draft) does not use up a one-shot Shift.
    var onAction: ((KeyAction) -> Bool)?
    /// Handwriting: a stroke started, a stroke ended (all strokes and the canvas size), a candidate was tapped,
    /// 重寫 was tapped.
    var onStrokeBegan: (() -> Void)?
    var onStrokesEnded: (([[InkPoint]], CGSize) -> Void)?
    var onSelectCandidate: ((Int) -> Void)?
    var onClearInk: (() -> Void)?
    /// Quick: a radical key or Shift was pressed.
    var onIMEInput: ((IMEInput) -> Void)?
    #if DEBUG
    var onDebugLongReturn: (() -> Void)? {
        get { bottomRow.onDebugLongReturn }
        set { bottomRow.onDebugLongReturn = newValue }
    }
    var onDebugBurst: (() -> Void)? {
        get { bottomRow.onDebugBurst }
        set { bottomRow.onDebugBurst = newValue }
    }
    var onDebugLongSpace: (() -> Void)? {
        get { bottomRow.onDebugLongSpace }
        set { bottomRow.onDebugLongSpace = newValue }
    }
    /// T13: a 2-second press on the status label turns the dictation probe on or off.
    var onDebugLongStatus: (() -> Void)? {
        get { topArea.onDebugLongStatus }
        set { topArea.onDebugLongStatus = newValue }
    }
    #endif

    /// The controller adds the system input-mode-list target to this button.
    var globeButton: UIButton { bottomRow.globeKey }
    /// The height the controller should give the keyboard for the state last applied.
    private(set) var preferredHeight = CGFloat(KeyboardMetrics.height(visibleTopRows: 2))

    private let topArea = TopAreaView()
    private let english = EnglishPageView()
    private let symbols = SymbolPageView()
    private var symbolsOrigin: SymbolOrigin?
    private let handwriting = HandwritingPageView()
    private let quick = QuickPageView()
    /// The input code last drawn; a press that clears it must not turn into a held delete of the text behind it.
    private var quickComposing = ""
    private let bottomRow = BottomRowView()
    #if DEBUG
    private let dictationPanel = DictationProbePanel()
    #endif
    private var shift = ShiftState()
    private var topRows = 2
    private var showsHandwriting = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        for view in [topArea, english, symbols, handwriting, quick, bottomRow] { addSubview(view) }
        #if DEBUG
        dictationPanel.isHidden = true
        addSubview(dictationPanel)
        #endif

        topArea.onAction = { [weak self] in _ = self?.onAction?($0) }
        bottomRow.onAction = { [weak self] in _ = self?.onAction?($0) }
        english.onLetter = { [weak self] text in self?.typeLetter(text) }
        english.onShift = { [weak self] in self?.tapShift() }
        english.onBackspace = { [weak self] in _ = self?.onAction?(.backspace) }
        symbols.onSymbol = { [weak self] text in _ = self?.onAction?(.character(text)) }
        symbols.onBackspace = { [weak self] in _ = self?.onAction?(.backspace) }
        topArea.onSelectCandidate = { [weak self] in self?.onSelectCandidate?($0) }
        handwriting.onStrokeBegan = { [weak self] in self?.onStrokeBegan?() }
        handwriting.onStrokesEnded = { [weak self] strokes, size in self?.onStrokesEnded?(strokes, size) }
        topArea.onBackspace = { [weak self] in _ = self?.onAction?(.backspace) }
        // A press that clears ink or candidates must not turn into a held delete of the text behind them.
        topArea.backspaceAllowsRepeat = { [weak self] in !(self?.handwriting.hasInk ?? false) }
        bottomRow.onClear = { [weak self] in self?.onClearInk?() }
        quick.onLetter = { [weak self] letter in self?.onIMEInput?(.key(letter)) }
        quick.onShift = { [weak self] in self?.onIMEInput?(.shift) }
        quick.onBackspace = { [weak self] in _ = self?.onAction?(.backspace) }
        quick.backspaceAllowsRepeat = { [weak self] in self?.quickComposing.isEmpty ?? true }
        handwriting.isHidden = true
        quick.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ state: KeyboardViewState) {
        KeyFeedback.isEnabled = state.hapticsEnabled
        KeyFeedback.prepare()
        topArea.apply(state)
        bottomRow.setGlobeVisible(state.showsGlobe)
        bottomRow.setChineseAvailable(state.chineseAvailable)
        bottomRow.setPage(state.page)
        let isSymbols: Bool, isChinese: Bool
        switch state.page {
        case .symbols: (isSymbols, isChinese) = (true, false)
        case .chinese: (isSymbols, isChinese) = (false, true)
        case .english: (isSymbols, isChinese) = (false, false)
        }
        if case .symbols(let origin) = state.page {
            // Every entry to the symbols page, and a change of origin, starts from the first layer.
            if symbolsOrigin != origin { symbols.enter(origin: origin) }
            symbolsOrigin = origin
        } else {
            symbolsOrigin = nil
        }
        let isHandwriting = isChinese && state.chineseMethod == .handwriting
        let isQuick = isChinese && state.chineseMethod == .quick
        english.isHidden = isSymbols || isChinese
        symbols.isHidden = !isSymbols
        handwriting.isHidden = !isHandwriting
        quick.isHidden = !isQuick
        quickComposing = state.composing
        quick.setShift(isQuick && state.quickShift)
        bottomRow.setClearVisible(isHandwriting)
        handwriting.setMessage(state.handwritingMessage)
        #if DEBUG
        // The panel covers the three English letter rows only in Remote mode; Local mode and the Chinese and symbols
        // pages are left as they are, so the letter keys stay usable there.
        if let lines = state.dictationProbeLines, state.page == .english, state.mode == .remote {
            dictationPanel.setLines(lines)
            dictationPanel.isHidden = false
        } else {
            dictationPanel.isHidden = true
        }
        #endif
        let rows = state.top.visibleRowCount
        if rows != topRows || isHandwriting != showsHandwriting {
            topRows = rows
            showsHandwriting = isHandwriting
            preferredHeight = CGFloat(KeyboardMetrics.height(visibleTopRows: rows, handwriting: isHandwriting))
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    func setGlobeVisible(_ visible: Bool) {
        bottomRow.setGlobeVisible(visible)
    }

    /// Drops the handwriting ink (after a commit, 重寫, or leaving the Chinese page).
    func clearInk() {
        handwriting.clearInk()
    }

    #if DEBUG
    /// Debug preview only: draws a sample character on the writing area.
    func showSampleInk() {
        handwriting.showSampleInk()
    }
    #endif

    /// Debug preview only: shows a symbols layer without any taps.
    func showSymbolLayer(_ index: Int) {
        symbols.showLayer(index)
    }

    /// Debug preview only: shows a Shift state without any taps.
    func setShift(_ mode: ShiftState.Mode) {
        shift = ShiftState()
        switch mode {
        case .off: break
        case .once: shift.tap(at: 0)
        case .capsLock: shift.tap(at: 0); shift.tap(at: 0.1)
        }
        english.setShift(shift.mode)
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: preferredHeight)
    }

    // MARK: Shift

    private func tapShift() {
        shift.tap(at: ProcessInfo.processInfo.systemUptime)
        english.setShift(shift.mode)
    }

    private func typeLetter(_ text: String) {
        guard onAction?(.character(text)) ?? false else { return }
        shift.characterTyped()
        english.setShift(shift.mode)
    }

    // MARK: Hit area

    /// A touch in the empty space between keys, between rows or beside the key area goes to the nearest key, like the
    /// system keyboard. Only a touch that lands on the root or on a page container is redirected; a control that
    /// already took the touch (a key, the candidate row, the writing canvas, the debug panel) is left alone. Reach is
    /// one key row height (42 pt), so the edges beside the half-key-inset second row still hit its end keys.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard let hit, isRedirectable(hit), point.y >= keysTop else { return hit }
        let keys = visibleKeys()
        let rects = keys.map { key -> HitRect in
            let frame = convert(key.bounds, from: key)
            return HitRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height)
        }
        guard let index = KeyHitResolver.nearest(
            to: HitPoint(x: point.x, y: point.y), in: rects, maxDistance: KeyHitResolver.defaultMaxDistance)
        else { return hit }
        return keys[index]
    }

    private var keysTop: CGFloat {
        CGFloat(Double(topRows) * KeyboardMetrics.topRowHeight + KeyboardMetrics.keyAreaVerticalInset)
    }

    private func isRedirectable(_ view: UIView) -> Bool {
        view === self || view === english || view === symbols || view === quick || view === handwriting
            || view === bottomRow
    }

    /// The keys a touch may be redirected to: those of the shown page and the bottom row that are visible, enabled
    /// and accept touches.
    private func visibleKeys() -> [KeyButton] {
        var result: [KeyButton] = []
        func collect(_ view: UIView) {
            for sub in view.subviews {
                if let key = sub as? KeyButton {
                    if isTouchable(key) { result.append(key) }
                } else {
                    collect(sub)
                }
            }
        }
        for page in [english, symbols, quick, handwriting, bottomRow] where isShown(page) { collect(page) }
        return result
    }

    private func isShown(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let v = current {
            if v.isHidden || v.alpha <= 0 { return false }
            current = v.superview
        }
        return true
    }

    private func isTouchable(_ key: KeyButton) -> Bool {
        isShown(key) && key.isEnabled && key.isUserInteractionEnabled
    }

    // MARK: Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = KeyboardMetrics.keyAreaSideInset
        let width = bounds.width
        let topHeight = Double(topRows) * KeyboardMetrics.topRowHeight
        topArea.frame = CGRect(x: 0, y: 0, width: width, height: topHeight)
        let keysTop = topHeight + KeyboardMetrics.keyAreaVerticalInset
        let letterHeight = EnglishPageView.height
        let pageFrame = CGRect(x: side, y: keysTop, width: width - 2 * side, height: letterHeight)
        english.frame = pageFrame
        symbols.frame = pageFrame
        quick.frame = pageFrame
        #if DEBUG
        // A few points taller than the keys, so their shadows do not show under the panel.
        dictationPanel.frame = pageFrame.insetBy(dx: 0, dy: -3).offsetBy(dx: 0, dy: 3)
        #endif
        let extra = showsHandwriting ? KeyboardMetrics.handwritingExtraHeight : 0
        handwriting.frame = CGRect(
            x: side, y: keysTop, width: width - 2 * side, height: letterHeight + KeyboardMetrics.handwritingExtraHeight)
        bottomRow.frame = CGRect(
            x: side, y: keysTop + letterHeight + extra + KeyboardMetrics.rowGap,
            width: width - 2 * side, height: KeyboardMetrics.keyRowHeight)
    }
}
