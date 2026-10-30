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

/// The top area, two or three rows of 36 pt:
/// row 1 mode toggle, status, transmit toggle; row 2 the draft (cursor keys, text, send); row 3 candidates.
final class TopAreaView: UIView {
    var onAction: ((KeyAction) -> Void)?
    /// The user tapped the candidate at this index.
    var onSelectCandidate: ((Int) -> Void)? {
        get { candidateBar.onSelect }
        set { candidateBar.onSelect = newValue }
    }

    private let modeToggle = SegmentToggle(
        titles: ["本機", "遠端"], identifier: "rk.mode", accessibilityName: "輸入位置")
    private let transmitToggle = SegmentToggle(
        titles: ["即時", "草稿"], identifier: "rk.transmit", accessibilityName: "傳送方式")
    private let statusLabel = UILabel()
    private let statusRow = UIStackView()

    private let draftRow = UIView()
    private let cursorLeft = KeyButton(style: .function, symbol: "chevron.left", label: "游標左移", identifier: "rk.cursorLeft")
    private let cursorRight = KeyButton(style: .function, symbol: "chevron.right", label: "游標右移", identifier: "rk.cursorRight")
    private let draftView = DraftTextView()
    private let sendButton = UIButton(type: .system)

    private let candidateRow = UIView()
    private let candidateBar = CandidateBarView()
    private let probeLabel = UILabel()
    private let stack = UIStackView()
    #if DEBUG
    /// T13: a 2-second press on the status label (Remote mode) turns the dictation probe on or off.
    var onDebugLongStatus: (() -> Void)?
    /// T13: the dictation probe checklist, in the candidate row while the probe is on and no candidates are shown.
    private let dictationLabel = UILabel()
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
        modeToggle.setSelected(state.mode == .remote ? 1 : 0)
        transmitToggle.setSelected(state.transmit == .draft ? 1 : 0)
        transmitToggle.isHidden = !top.showsTransmitToggle
        statusLabel.isHidden = !top.showsStatus
        statusLabel.text = state.statusText
        // `rk.status` keeps the BLE link state name as its value, which the UI tests read.
        statusLabel.accessibilityValue = state.linkName
        draftRow.isHidden = !top.showsDraftRow
        candidateRow.isHidden = !top.showsCandidateRow
        draftView.set(draft: state.draft)
        setSendEnabled(top.sendEnabled)
        probeLabel.text = state.probeText
        candidateBar.setCandidates(state.candidates)
        // The small build line gives way to the candidates.
        probeLabel.isHidden = !state.candidates.isEmpty
        #if DEBUG
        // The dictation checklist replaces the build line; candidates (Chinese page) still win.
        dictationLabel.text = state.dictationProbeLines?.joined(separator: "\n")
        dictationLabel.isHidden = state.dictationProbeLines == nil || !state.candidates.isEmpty
        if state.dictationProbeLines != nil { probeLabel.isHidden = true }
        #endif
    }

    // MARK: Rows

    private func buildStatusRow() {
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabel
        statusLabel.numberOfLines = 2
        statusLabel.adjustsFontSizeToFitWidth = true
        statusLabel.minimumScaleFactor = 0.8
        statusLabel.accessibilityIdentifier = "rk.status"
        statusLabel.accessibilityValue = KeyboardLinkState.idle.name
        statusLabel.text = KeyboardLinkState.idle.statusText
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        #if DEBUG
        statusLabel.isUserInteractionEnabled = true
        let press = UILongPressGestureRecognizer(target: self, action: #selector(statusLongPressed(_:)))
        press.minimumPressDuration = 2
        statusLabel.addGestureRecognizer(press)
        #endif
        modeToggle.addAction(UIAction { [weak self] _ in self?.onAction?(.toggleMode) }, for: .touchUpInside)
        transmitToggle.addAction(UIAction { [weak self] _ in self?.onAction?(.toggleTransmit) }, for: .touchUpInside)
        modeToggle.setContentHuggingPriority(.required, for: .horizontal)
        modeToggle.setContentCompressionResistancePriority(.required, for: .horizontal)
        transmitToggle.setContentHuggingPriority(.required, for: .horizontal)
        transmitToggle.setContentCompressionResistancePriority(.required, for: .horizontal)

        statusRow.axis = .horizontal
        statusRow.alignment = .center
        statusRow.spacing = 8
        statusRow.isLayoutMarginsRelativeArrangement = true
        statusRow.layoutMargins = UIEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        statusRow.addArrangedSubview(modeToggle)
        statusRow.addArrangedSubview(statusLabel)
        // Takes the spare width, so the toggles stay compact when the status label is hidden (Local mode).
        let spacer = UIView()
        spacer.setContentHuggingPriority(UILayoutPriority(1), for: .horizontal)
        spacer.setContentCompressionResistancePriority(UILayoutPriority(1), for: .horizontal)
        statusRow.addArrangedSubview(spacer)
        statusRow.addArrangedSubview(transmitToggle)
    }

    #if DEBUG
    @objc private func statusLongPressed(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began else { return }
        onDebugLongStatus?()
    }
    #endif

    private func buildDraftRow() {
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

    /// The Chinese candidates when there are any; otherwise the small build line the earlier tasks showed.
    private func buildCandidateRow() {
        candidateBar.translatesAutoresizingMaskIntoConstraints = false
        candidateRow.addSubview(candidateBar)
        NSLayoutConstraint.activate([
            candidateBar.leadingAnchor.constraint(equalTo: candidateRow.leadingAnchor),
            candidateBar.trailingAnchor.constraint(equalTo: candidateRow.trailingAnchor),
            candidateBar.topAnchor.constraint(equalTo: candidateRow.topAnchor),
            candidateBar.bottomAnchor.constraint(equalTo: candidateRow.bottomAnchor)
        ])
        probeLabel.font = .systemFont(ofSize: 9)
        probeLabel.textColor = .tertiaryLabel
        probeLabel.textAlignment = .right
        probeLabel.adjustsFontSizeToFitWidth = true
        probeLabel.minimumScaleFactor = 0.7
        probeLabel.translatesAutoresizingMaskIntoConstraints = false
        candidateRow.addSubview(probeLabel)
        NSLayoutConstraint.activate([
            probeLabel.trailingAnchor.constraint(equalTo: candidateRow.trailingAnchor, constant: -8),
            probeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: candidateRow.leadingAnchor, constant: 8),
            probeLabel.centerYAnchor.constraint(equalTo: candidateRow.centerYAnchor)
        ])
        #if DEBUG
        dictationLabel.font = .systemFont(ofSize: 10)
        dictationLabel.textColor = .secondaryLabel
        dictationLabel.numberOfLines = 2
        dictationLabel.adjustsFontSizeToFitWidth = true
        dictationLabel.minimumScaleFactor = 0.6
        dictationLabel.accessibilityIdentifier = "rk.dictationProbe"
        dictationLabel.isHidden = true
        dictationLabel.translatesAutoresizingMaskIntoConstraints = false
        candidateRow.addSubview(dictationLabel)
        NSLayoutConstraint.activate([
            dictationLabel.leadingAnchor.constraint(equalTo: candidateRow.leadingAnchor, constant: 8),
            dictationLabel.trailingAnchor.constraint(equalTo: candidateRow.trailingAnchor, constant: -8),
            dictationLabel.centerYAnchor.constraint(equalTo: candidateRow.centerYAnchor)
        ])
        #endif
    }
}

/// The draft text with a caret. Text before the caret is cut at its head and text after it at its tail, so the
/// caret stays in view however long the draft is.
final class DraftTextView: UIView {
    private let before = UILabel()
    private let after = UILabel()
    private let caret = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .tertiarySystemFill
        layer.cornerRadius = 6
        accessibilityIdentifier = "rk.draft"
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = "草稿"
        for label in [before, after] {
            label.font = .systemFont(ofSize: 17)
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
        before.text = Self.singleLine(draft.textBeforeCursor)
        if draft.isEmpty {
            after.text = "輸入草稿"
            after.textColor = .tertiaryLabel
        } else {
            after.text = Self.singleLine(draft.textAfterCursor)
            after.textColor = .label
        }
        accessibilityValue = draft.isEmpty ? "空白" : draft.text
    }

    /// A line break in the draft is shown as a return mark so the draft stays on one line.
    private static func singleLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: "\u{23CE}")
    }
}
