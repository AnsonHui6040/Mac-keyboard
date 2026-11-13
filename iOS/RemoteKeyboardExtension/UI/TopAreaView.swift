import RemoteKeyboardCore
import UIKit

/// A two-choice switch drawn as two words with the current one highlighted. A tap anywhere on it asks to switch.
final class SegmentToggle: UIControl {
    private let labels: [UILabel]
    private let highlight = UIView()
    private var selectedIndex = 0

    init(titles: [String], identifier: String, accessibilityName: String) {
        precondition(titles.count == 2)
        labels = titles.map { title in
            let label = UILabel()
            label.text = title
            label.font = .systemFont(ofSize: 13, weight: .medium)
            label.textAlignment = .center
            label.isAccessibilityElement = false
            return label
        }
        super.init(frame: .zero)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 8
        highlight.backgroundColor = .systemBackground
        highlight.layer.cornerRadius = 6
        highlight.layer.shadowColor = UIColor.black.cgColor
        highlight.layer.shadowOpacity = 0.2
        highlight.layer.shadowRadius = 1
        highlight.layer.shadowOffset = CGSize(width: 0, height: 0.5)
        addSubview(highlight)
        labels.forEach(addSubview)
        addAction(UIAction { _ in KeyFeedback.touchDown() }, for: .touchDown)
        isAccessibilityElement = true
        accessibilityIdentifier = identifier
        accessibilityLabel = accessibilityName
        accessibilityTraits = .button
        accessibilityValue = titles[0]
        setSelected(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setSelected(_ index: Int) {
        selectedIndex = index
        accessibilityValue = labels[index].text
        for (i, label) in labels.enumerated() {
            label.textColor = i == index ? .label : .secondaryLabel
        }
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        let widest = labels.map { $0.intrinsicContentSize.width }.max() ?? 0
        return CGSize(width: 2 * (widest + 14), height: 28)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let half = bounds.width / 2
        for (i, label) in labels.enumerated() {
            label.frame = CGRect(x: Double(i) * half, y: 0, width: half, height: bounds.height)
        }
        highlight.frame = CGRect(x: Double(selectedIndex) * half, y: 0, width: half, height: bounds.height)
            .insetBy(dx: 2, dy: 2)
    }

    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }
}

/// The status cell. Normally one label with the short status. With a current host it has two lines, the host's name (one
/// line, cut at the end when too long) over the short status. Only while two or more hosts are paired is it a control: a
/// tap anywhere on it asks for the next host. With one host it names that host and does nothing: no fill, no click, no
/// button role. Without a host name it is the plain single-line label.
final class StatusCell: UIControl {
    let titleLabel = UILabel()
    let statusLabel = UILabel()
    private let stack = UIStackView()
    /// Whether a tap switches the host (a host name is shown and two or more hosts are paired).
    private(set) var switchesHost = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 11, weight: .medium)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isHidden = true
        titleLabel.isAccessibilityElement = false
        titleLabel.accessibilityIdentifier = "rk.hostName"
        statusLabel.isAccessibilityElement = true
        stack.axis = .vertical
        stack.alignment = .fill
        stack.distribution = .fill
        stack.isUserInteractionEnabled = false
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(statusLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        layer.cornerRadius = 8
        addAction(UIAction { [weak self] _ in if self?.switchesHost == true { KeyFeedback.touchDown() } }, for: .touchDown)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// - Parameters:
    ///   - title: the current host's name; `nil` keeps the single-line cell that takes no touch.
    ///   - twoLines: the status is short enough to sit under the name. A longer note takes the whole cell for itself, and the
    ///     cell still switches the host when `switchesHost` is true.
    ///   - switchesHost: two or more hosts are paired, so a tap switches to the next one. False with a single host.
    func setTitle(_ title: String?, twoLines: Bool, switchesHost: Bool, accessibilityValue value: String) {
        self.switchesHost = title != nil && switchesHost
        titleLabel.text = title
        titleLabel.isHidden = !(title != nil && twoLines)
        // A cell that switches the host reads as one control (a tap target) and shows its state as a soft fill like the toggles.
        backgroundColor = self.switchesHost ? .tertiarySystemFill : .clear
        // With a name the cell is one accessibility element for both lines; with one host it is static text, not a button.
        isAccessibilityElement = title != nil
        accessibilityHint = nil
        accessibilityTraits = .staticText
        if let title {
            accessibilityLabel = "\(title)，\(statusLabel.text ?? "")"
            accessibilityIdentifier = "rk.status"
            accessibilityValue = value
            if self.switchesHost {
                accessibilityHint = "輕點切換到下一台電腦"
                accessibilityTraits = .button
            }
        }
        if title == nil {
            // No stale name or identifier: the plain label carries `rk.status` on its own.
            accessibilityLabel = nil
            accessibilityValue = nil
            accessibilityIdentifier = nil
        }
        statusLabel.isAccessibilityElement = title == nil
    }

    override func accessibilityActivate() -> Bool {
        guard switchesHost else { return false }
        sendActions(for: .touchUpInside)
        return true
    }
}

/// The top area, one to three rows of 36 pt:
/// row 1 mode toggle, status, touchpad key, dismiss key, transmit toggle in five equal cells; then the draft (cursor
/// keys, text, send) when shown; then the candidates on the Quick page. The stack divides its height equally, so every
/// row is 36 pt.
final class TopAreaView: UIView {
    var onAction: ((KeyAction) -> Void)?
    /// The user tapped the candidate at this index.
    var onSelectCandidate: ((Int) -> Void)? {
        get { candidateBar.onSelect }
        set { candidateBar.onSelect = newValue }
    }

    /// The key beside the dismiss key was tapped: open the touchpad page, or go back to the keyboard.
    var onTrackpadToggle: (() -> Void)?

    private let modeToggle = SegmentToggle(
        titles: ["本機", "遠端"], identifier: "rk.mode", accessibilityName: "輸入位置")
    private let dismissKey = KeyButton(
        style: .function, symbol: "keyboard.chevron.compact.down", label: "收起鍵盤", identifier: "rk.dismiss")
    private let transmitToggle = SegmentToggle(
        titles: ["即時", "草稿"], identifier: "rk.transmit", accessibilityName: "傳送方式")
    /// 觸控板 on the keyboard (usable only on a connected Remote link), 鍵盤 on the touchpad page (always usable).
    private let trackpadKey = KeyButton(
        style: .function, title: "觸控板", label: "觸控板", identifier: "rk.trackpad.toggle")
    private let statusCell = StatusCell()
    private var statusLabel: UILabel { statusCell.statusLabel }
    private let statusRow = UIStackView()

    private let draftRow = UIView()
    private let cursorLeft = KeyButton(style: .function, symbol: "chevron.left", label: "游標左移", identifier: "rk.cursorLeft")
    private let cursorRight = KeyButton(style: .function, symbol: "chevron.right", label: "游標右移", identifier: "rk.cursorRight")
    private let draftView = DraftTextView()
    private let sendButton = UIButton(type: .system)

    private let candidateRow = UIView()
    private let candidateBar = CandidateBarView()
    private let stack = UIStackView()
    #if DEBUG
    /// T13: a 2-second press on the status label (Remote mode) turns the dictation probe on or off.
    var onDebugLongStatus: (() -> Void)?
    #endif

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildStatusRow()
        buildDraftRow()
        buildCandidateRow()
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.addArrangedSubview(statusRow)
        stack.addArrangedSubview(draftRow)
        stack.addArrangedSubview(candidateRow)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ state: KeyboardViewState) {
        let top = state.top
        let onPad = state.trackpad != nil
        modeToggle.setSelected(state.mode == .remote ? 1 : 0)
        transmitToggle.setSelected(state.transmit == .draft ? 1 : 0)
        // On the touchpad page only the top row is left: the mode and transmit switches have nothing to do there.
        // A hidden control keeps its cell, so the others do not move.
        modeToggle.isHidden = onPad
        transmitToggle.isHidden = !top.showsTransmitToggle || onPad
        trackpadKey.setTitle(onPad ? "鍵盤" : "觸控板", for: .normal)
        trackpadKey.accessibilityLabel = onPad ? "回到鍵盤" : "觸控板"
        // Local mode has no touchpad: the key is hidden and its cell stays. In Remote mode it is grey until connected.
        trackpadKey.isHidden = !top.showsTrackpadKey && !onPad
        trackpadKey.isEnabled = onPad || state.trackpadAvailable
        applyStatus(state, visible: top.showsStatus)
        draftRow.isHidden = !top.showsDraftRow || onPad
        candidateRow.isHidden = !top.showsCandidateRow || onPad
        draftView.set(draft: state.draft)
        setSendEnabled(top.sendEnabled)
        // Only Quick has its candidates here; the handwriting page draws its own over the writing area.
        let isQuick = state.page == .chinese && state.chineseMethod == .quick
        candidateBar.setCandidates(isQuick ? state.candidates : [], composing: isQuick ? state.composing : "")
    }

    /// Status texts up to this many characters are kept on one line (the cell is one fifth of the width, 68 to 71 pt).
    private static let singleLineStatusLimit = 6

    private static let standardStatusTexts: Set<String> = [
        StatusLine.connectedText, StatusLine.disconnectedText, StatusLine.notPairedShortText
    ]

    private func applyStatus(_ state: KeyboardViewState, visible: Bool) {
        guard visible, let display = state.status else {
            statusCell.isHidden = true
            return
        }
        statusCell.isHidden = false
        statusLabel.text = display.text
        // A short state such as 密碼不能輸入 stays on one line and shrinks to fit rather than breaking in the middle.
        let isShort = display.text.count <= Self.singleLineStatusLimit
        statusLabel.numberOfLines = isShort ? 1 : 2
        statusLabel.textColor = display.tone == .connected ? .systemGreen : .systemRed
        // With a host name above it the short status shares the 28 pt cell and takes the smaller size too. The 13 pt size is
        // left for the unpaired 尚未配對, which has no name; a note or a warning is longer and gets the smaller size.
        let underName = display.title != nil && isShort
        statusLabel.font = Self.standardStatusTexts.contains(display.text) && !underName
            ? .systemFont(ofSize: 13, weight: .medium) : .systemFont(ofSize: 11)
        statusCell.setTitle(
            display.title, twoLines: isShort, switchesHost: display.switchesHost, accessibilityValue: state.linkName)
        #if DEBUG
        // The UI tests read the long line (app name, latency, note) from the label.
        statusLabel.accessibilityLabel = state.statusDetail
        #else
        statusLabel.accessibilityLabel = display.text
        #endif
        // `rk.status` keeps the BLE link state name as its value, which the UI tests read.
        statusLabel.accessibilityValue = state.linkName
        #if DEBUG
        if let title = display.title { statusCell.accessibilityLabel = "\(title)，\(state.statusDetail)" }
        #endif
    }

    // MARK: Rows

    private func buildStatusRow() {
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textColor = .systemRed
        statusLabel.textAlignment = .center
        statusLabel.numberOfLines = 2
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.8
        statusLabel.accessibilityIdentifier = "rk.status"
        statusLabel.accessibilityValue = KeyboardLinkState.idle.name
        statusLabel.text = StatusLine.disconnectedText
        #if DEBUG
        let press = UILongPressGestureRecognizer(target: self, action: #selector(statusLongPressed(_:)))
        press.minimumPressDuration = 2
        statusCell.addGestureRecognizer(press)
        #endif
        statusCell.addAction(UIAction { [weak self] _ in
            guard self?.statusCell.switchesHost == true else { return }
            self?.onAction?(.cycleHost)
        }, for: .touchUpInside)
        modeToggle.addAction(UIAction { [weak self] _ in self?.onAction?(.toggleMode) }, for: .touchUpInside)
        transmitToggle.addAction(UIAction { [weak self] _ in self?.onAction?(.toggleTransmit) }, for: .touchUpInside)
        trackpadKey.titleLabel?.font = .systemFont(ofSize: 14)
        dismissKey.onTap = { [weak self] in self?.onAction?(.dismissKeyboard) }
        dismissKey.layer.shadowOpacity = 0
        trackpadKey.onTap = { [weak self] in self?.onTrackpadToggle?() }
        trackpadKey.layer.shadowOpacity = 0
        trackpadKey.isEnabled = false

        // Five equal cells. Each control fills its cell, and a hidden control leaves the cell empty, so nothing moves.
        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.distribution = .fillEqually
        statusRow.spacing = 6
        statusRow.isLayoutMarginsRelativeArrangement = true
        statusRow.layoutMargins = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        for control in [modeToggle, statusCell, trackpadKey, dismissKey, transmitToggle] {
            statusRow.addArrangedSubview(Self.cell(holding: control))
        }
    }

    private static func cell(holding view: UIView) -> UIView {
        let cell = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            view.topAnchor.constraint(equalTo: cell.topAnchor),
            view.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
            cell.heightAnchor.constraint(equalToConstant: 28)
        ])
        return cell
    }

    #if DEBUG
    @objc private func statusLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        onDebugLongStatus?()
    }
    #endif

    private func buildDraftRow() {
        draftView.onSetCursor = { [weak self] index in self?.onAction?(.setDraftCursor(index)) }
        cursorLeft.onTap = { [weak self] in self?.onAction?(.cursorLeft) }
        cursorRight.onTap = { [weak self] in self?.onAction?(.cursorRight) }
        for key in [cursorLeft, cursorRight] {
            key.layer.shadowOpacity = 0
            key.layer.cornerRadius = 6
        }
        sendButton.setTitle("傳送", for: .normal)
        sendButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        sendButton.layer.cornerRadius = 6
        sendButton.accessibilityIdentifier = "rk.send"
        sendButton.accessibilityLabel = "傳送草稿"
        sendButton.addAction(UIAction { _ in KeyFeedback.touchDown() }, for: .touchDown)
        sendButton.addAction(UIAction { [weak self] _ in self?.onAction?(.sendDraft) }, for: .touchUpInside)
        setSendEnabled(false)

        let row = UIStackView(arrangedSubviews: [cursorLeft, cursorRight, draftView, sendButton])
        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = 6
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        row.translatesAutoresizingMaskIntoConstraints = false
        draftRow.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: draftRow.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: draftRow.trailingAnchor),
            row.topAnchor.constraint(equalTo: draftRow.topAnchor),
            row.bottomAnchor.constraint(equalTo: draftRow.bottomAnchor),
            cursorLeft.widthAnchor.constraint(equalToConstant: 38),
            cursorRight.widthAnchor.constraint(equalToConstant: 38),
            sendButton.widthAnchor.constraint(equalToConstant: 60)
        ])
    }

    private func setSendEnabled(_ enabled: Bool) {
        sendButton.isEnabled = enabled
        sendButton.backgroundColor = enabled ? .systemBlue : .systemFill
        sendButton.setTitleColor(enabled ? .white : .tertiaryLabel, for: .normal)
        sendButton.setTitleColor(.tertiaryLabel, for: .disabled)
    }

    /// The Quick candidates, a strip that fills the row.
    private func buildCandidateRow() {
        candidateBar.translatesAutoresizingMaskIntoConstraints = false
        candidateRow.addSubview(candidateBar)
        NSLayoutConstraint.activate([
            candidateBar.leadingAnchor.constraint(equalTo: candidateRow.leadingAnchor),
            candidateBar.trailingAnchor.constraint(equalTo: candidateRow.trailingAnchor),
            candidateBar.topAnchor.constraint(equalTo: candidateRow.topAnchor),
            candidateBar.bottomAnchor.constraint(equalTo: candidateRow.bottomAnchor)
        ])
    }
}

/// The draft text with a caret. Text before the caret is cut at its head and text after it at its tail, so the
/// caret stays in view however long the draft is.
///
/// A touch moves the caret to the nearest visible boundary, and a finger dragged along the draft moves it
/// continuously. A real text field cannot live in a keyboard extension, so the view measures what the two labels show
/// and `DraftCaretHitTest` decides where a point lands. It is a `UIControl` like the keys, which gets the touch down at
/// once; the click plays once per touch, not per drag step. An empty draft takes no touch.
final class DraftTextView: UIControl {
    /// The caret should sit before the Character at this index (counted like `DraftBuffer`).
    var onSetCursor: ((Int) -> Void)?

    private let before = UILabel()
    private let after = UILabel()
    private let caret = UIView()
    private static let font = UIFont.systemFont(ofSize: 17)
    /// What the labels show, one string per Character of the draft, so an index here is a draft index.
    private var beforeShown: [String] = []
    private var afterShown: [String] = []
    private var cursorIndex = 0
    private var isDraftEmpty = true
    private var widths: [String: Double] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 6
        accessibilityIdentifier = "rk.draft"
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = "草稿"
        for label in [before, after] {
            label.font = Self.font
            label.textColor = .label
            label.numberOfLines = 1
        }
        before.lineBreakMode = .byTruncatingHead
        after.lineBreakMode = .byTruncatingTail
        caret.backgroundColor = .systemBlue
        caret.layer.cornerRadius = 1

        let row = UIStackView(arrangedSubviews: [before, caret, after])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 0
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        before.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        before.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        after.setContentHuggingPriority(.defaultLow, for: .horizontal)
        after.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        caret.setContentHuggingPriority(.required, for: .horizontal)
        caret.setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            caret.widthAnchor.constraint(equalToConstant: 2),
            caret.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func set(draft: DraftBuffer) {
        beforeShown = Self.shown(draft.textBeforeCursor)
        afterShown = Self.shown(draft.textAfterCursor)
        cursorIndex = draft.cursor
        isDraftEmpty = draft.isEmpty
        before.text = beforeShown.joined()
        if draft.isEmpty {
            after.text = "輸入草稿"
            after.textColor = .tertiaryLabel
        } else {
            after.text = afterShown.joined()
            after.textColor = .label
        }
        accessibilityValue = draft.isEmpty ? "空白" : draft.text
    }

    /// One string per Character of `text`; a line break is shown as a return mark so the draft stays on one line.
    private static func shown(_ text: String) -> [String] {
        text.map { $0 == "\n" || $0 == "\r\n" ? "\u{23CE}" : String($0) }
    }

    // MARK: Touches

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard !isDraftEmpty else { return false }
        KeyFeedback.touchDown()
        moveCaret(to: touch)
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        moveCaret(to: touch)
        return true
    }

    private func moveCaret(to touch: UITouch) {
        guard let index = DraftCaretHitTest.nearestIndex(x: touch.location(in: self).x, stops: stops()),
            index != cursorIndex
        else { return }
        onSetCursor?(index)
    }

    /// The cursor positions the two labels show right now, with the x each is drawn at. The earlier move may have left a
    /// layout pass pending, so lay out first.
    private func stops() -> [DraftCaretHitTest.Stop] {
        layoutIfNeeded()
        let ellipsis = width(of: "\u{2026}")
        return DraftCaretHitTest.stopsBefore(
            widths: beforeShown.map(width(of:)), originX: before.frame.minX, available: before.frame.width, ellipsis: ellipsis)
            + DraftCaretHitTest.stopsAfter(
                widths: afterShown.map(width(of:)), originX: after.frame.minX, available: after.frame.width, ellipsis: ellipsis,
                baseIndex: cursorIndex)
    }

    private func width(of character: String) -> Double {
        if let known = widths[character] { return known }
        let measured = Double((character as NSString).size(withAttributes: [.font: Self.font]).width)
        widths[character] = measured
        return measured
    }
}
