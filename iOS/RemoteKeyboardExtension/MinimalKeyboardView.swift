import UIKit
import RemoteKeyboardCore

final class MinimalKeyboardView: UIView {
    var onAction: ((KeyAction) -> Void)?
    #if DEBUG
    /// Long-pressing `return` for two seconds; the debug build uses it to send one 3,000-character text (T07 check).
    var onDebugLongReturn: (() -> Void)?
    #endif
    let globeButton = UIButton(type: .system)
    private let modeButton = UIButton(type: .system)
    private let statusLabel = UILabel()

    private var isShifted = false
    private var letterButtons: [UIButton] = []
    private var shiftButton = UIButton(type: .system)
    private let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]

    init(showsGlobeKey: Bool, probeText: String) {
        super.init(frame: .zero)
        build(probeText: probeText)
        setGlobeVisible(showsGlobeKey)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setGlobeVisible(_ visible: Bool) {
        globeButton.isHidden = !visible
    }

    /// `linkName` stays the BLE link state name so UI tests can read the link regardless of the visible wording.
    func setStatus(text: String, linkName: String) {
        statusLabel.text = text
        statusLabel.accessibilityValue = linkName
    }

    func setMode(_ mode: KeyboardMode) {
        modeButton.setTitle(mode == .remote ? "遠端" : "本機", for: .normal)
        modeButton.accessibilityValue = mode.rawValue
        modeButton.backgroundColor = mode == .remote ? .systemBlue.withAlphaComponent(0.3) : .secondarySystemBackground
    }

    // MARK: - Layout

    private func build(probeText: String) {
        let probe = UILabel()
        probe.text = probeText
        probe.font = .systemFont(ofSize: 10)
        probe.textColor = .secondaryLabel
        probe.textAlignment = .right

        statusLabel.text = KeyboardLinkState.idle.statusText
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .secondaryLabel
        statusLabel.accessibilityIdentifier = "rk.status"
        statusLabel.accessibilityValue = KeyboardLinkState.idle.name

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 6
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false

        for (index, row) in rows.enumerated() {
            let rowStack = makeRow()
            if index == 2 {
                shiftButton = makeKey(title: "⇧") { [weak self] in self?.toggleShift() }
                rowStack.addArrangedSubview(shiftButton)
            }
            for letter in row {
                let button = makeKey(title: String(letter)) { [weak self] in self?.typeLetter(letter) }
                letterButtons.append(button)
                rowStack.addArrangedSubview(button)
            }
            if index == 2 {
                rowStack.addArrangedSubview(makeKey(title: "⌫") { [weak self] in self?.onAction?(.backspace) })
            }
            stack.addArrangedSubview(rowStack)
        }

        let bottom = makeRow()
        bottom.distribution = .fill
        configureGlobe()
        bottom.addArrangedSubview(globeButton)
        configureModeKey()
        bottom.addArrangedSubview(modeButton)
        let space = makeKey(title: "space") { [weak self] in self?.onAction?(.space) }
        bottom.addArrangedSubview(space)
        let returnKey = makeKey(title: "return") { [weak self] in self?.onAction?(.returnKey) }
        bottom.addArrangedSubview(returnKey)
        #if DEBUG
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(debugLongReturn(_:)))
        longPress.minimumPressDuration = 2
        returnKey.addGestureRecognizer(longPress)
        #endif
        // Hidden arranged subviews take no space in a fill stack, so these hold in both states.
        let spaceRatio = space.widthAnchor.constraint(equalTo: returnKey.widthAnchor, multiplier: 4)
        spaceRatio.priority = UILayoutPriority(999)
        let globeRatio = globeButton.widthAnchor.constraint(equalTo: returnKey.widthAnchor)
        globeRatio.priority = UILayoutPriority(999)
        let modeRatio = modeButton.widthAnchor.constraint(equalTo: returnKey.widthAnchor)
        modeRatio.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([spaceRatio, globeRatio, modeRatio])
        stack.addArrangedSubview(bottom)

        probe.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)
        addSubview(probe)
        addSubview(stack)
        let height = heightAnchor.constraint(equalToConstant: 230)
        height.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            height,
            probe.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            probe.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: probe.leadingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: probe.bottomAnchor, constant: 2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }

    #if DEBUG
    @objc private func debugLongReturn(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began { onDebugLongReturn?() }
    }
    #endif

    private func makeRow() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 4
        row.distribution = .fillEqually
        return row
    }

    private func configureGlobe() {
        globeButton.setTitle("🌐", for: .normal)
        styleKey(globeButton)
    }

    private func configureModeKey() {
        styleKey(modeButton)
        modeButton.accessibilityIdentifier = "rk.mode"
        modeButton.addAction(UIAction { [weak self] _ in self?.onAction?(.toggleMode) }, for: .touchUpInside)
        setMode(.local)
    }

    private func makeKey(title: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        styleKey(button)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func styleKey(_ button: UIButton) {
        button.titleLabel?.font = .systemFont(ofSize: 18)
        button.setTitleColor(.label, for: .normal)
        button.backgroundColor = .secondarySystemBackground
        button.layer.cornerRadius = 5
    }

    // MARK: - Shift

    private func typeLetter(_ letter: Character) {
        let text = isShifted ? String(letter).uppercased() : String(letter)
        onAction?(.character(text))
        if isShifted { toggleShift() }
    }

    private func toggleShift() {
        isShifted.toggle()
        for button in letterButtons {
            let title = button.title(for: .normal) ?? ""
            button.setTitle(isShifted ? title.uppercased() : title.lowercased(), for: .normal)
        }
        shiftButton.backgroundColor = isShifted ? .systemBlue.withAlphaComponent(0.3) : .secondarySystemBackground
    }
}
