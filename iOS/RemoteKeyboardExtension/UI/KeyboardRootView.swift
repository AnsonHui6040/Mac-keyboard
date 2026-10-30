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
    /// Light haptic on every key at touch down. True only when the keyboard has Full Access; the preview passes false.
    var hapticsEnabled: Bool
}

/// The whole keyboard: top area, key rows and bottom row. It reports every key as a `KeyAction`.
final class KeyboardRootView: UIView {
    /// Returns whether the key was taken; a refused key (full draft) does not use up a one-shot Shift.
    var onAction: ((KeyAction) -> Bool)?
    #if DEBUG
    var onDebugLongReturn: (() -> Void)? {
        get { bottomRow.onDebugLongReturn }
        set { bottomRow.onDebugLongReturn = newValue }
    }
    #endif

    /// The controller adds the system input-mode-list target to this button.
    var globeButton: UIButton { bottomRow.globeKey }
    /// The height the controller should give the keyboard for the state last applied.
    private(set) var preferredHeight = CGFloat(KeyboardMetrics.height(visibleTopRows: 2))

    private let topArea = TopAreaView()
    private let english = EnglishPageView()
    private let symbols = SymbolsPageView()
    private let bottomRow = BottomRowView()
    private var shift = ShiftState()
    private var topRows = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        for view in [topArea, english, symbols, bottomRow] { addSubview(view) }

        topArea.onAction = { [weak self] in _ = self?.onAction?($0) }
        bottomRow.onAction = { [weak self] in _ = self?.onAction?($0) }
        english.onLetter = { [weak self] text in self?.typeLetter(text) }
        english.onShift = { [weak self] in self?.tapShift() }
        english.onBackspace = { [weak self] in _ = self?.onAction?(.backspace) }
        symbols.onSymbol = { [weak self] text in _ = self?.onAction?(.character(text)) }
        symbols.onBackspace = { [weak self] in _ = self?.onAction?(.backspace) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ state: KeyboardViewState) {
        KeyFeedback.isEnabled = state.hapticsEnabled
        topArea.apply(state)
        bottomRow.setGlobeVisible(state.showsGlobe)
        bottomRow.setChineseAvailable(state.chineseAvailable)
        bottomRow.setPage(state.page)
        // The Chinese page arrives in a later task; until then its place is taken by the English letters.
        if case .symbols = state.page {
            english.isHidden = true
            symbols.isHidden = false
        } else {
            english.isHidden = false
            symbols.isHidden = true
        }
        let rows = state.top.visibleRowCount
        if rows != topRows {
            topRows = rows
            preferredHeight = CGFloat(KeyboardMetrics.height(visibleTopRows: rows))
            invalidateIntrinsicContentSize()
            setNeedsLayout()
        }
    }

    func setGlobeVisible(_ visible: Bool) {
        bottomRow.setGlobeVisible(visible)
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
        bottomRow.frame = CGRect(
            x: side, y: keysTop + letterHeight + KeyboardMetrics.rowGap,
            width: width - 2 * side, height: KeyboardMetrics.keyRowHeight)
    }
}

/// Temporary symbols page (T11 replaces it with the real layouts): digits, a few punctuation rows and delete.
final class SymbolsPageView: UIView {
    var onSymbol: ((String) -> Void)?
    var onBackspace: (() -> Void)?

    private static let rows = ["1234567890", "-/:;()$&@\"", ".,?!'"]
    private var rowKeys: [[KeyButton]] = []
    private let backspaceKey = KeyButton(
        style: .function, symbol: "delete.left", label: "刪除", identifier: "rk.backspace")

    override init(frame: CGRect) {
        super.init(frame: frame)
        for row in Self.rows {
            var keys: [KeyButton] = []
            for symbol in row {
                let text = String(symbol)
                let key = KeyButton(style: .letter, title: text, label: text)
                key.onTap = { [weak self] in self?.onSymbol?(text) }
                addSubview(key)
                keys.append(key)
            }
            rowKeys.append(keys)
        }
        backspaceKey.onRepeat = { [weak self] in self?.onBackspace?() }
        addSubview(backspaceKey)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let gap = KeyboardMetrics.keyGap
        let height = KeyboardMetrics.keyRowHeight
        let rowStep = height + KeyboardMetrics.rowGap
        let width = bounds.width
        for row in 0..<2 {
            for (index, frame) in KeyRowLayout.equalKeys(count: 10, x: 0, width: width, gap: gap).enumerated() {
                rowKeys[row][index].frame = CGRect(x: frame.x, y: Double(row) * rowStep, width: frame.width, height: height)
            }
        }
        let key = (width - 9 * gap) / 10
        let function = key * 1.5
        let y = 2 * rowStep
        let symbolsWidth = width - function - 2 * gap
        for (index, frame) in KeyRowLayout.equalKeys(count: 5, x: 0, width: symbolsWidth, gap: gap).enumerated() {
            rowKeys[2][index].frame = CGRect(x: frame.x, y: y, width: frame.width, height: height)
        }
        backspaceKey.frame = CGRect(x: width - function, y: y, width: function, height: height)
    }
}
