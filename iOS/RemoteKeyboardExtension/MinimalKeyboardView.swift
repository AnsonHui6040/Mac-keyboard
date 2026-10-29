import UIKit
import RemoteKeyboardCore

final class MinimalKeyboardView: UIView {
    var onAction: ((KeyAction) -> Void)?
    let globeButton = UIButton(type: .system)

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

    // MARK: - Layout

    private func build(probeText: String) {
        let probe = UILabel()
        probe.text = probeText
        probe.font = .systemFont(ofSize: 10)
        probe.textColor = .secondaryLabel
        probe.textAlignment = .right

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
        configureGlobe()
        bottom.addArrangedSubview(globeButton)
        let space = makeKey(title: "space") { [weak self] in self?.onAction?(.space) }
        bottom.addArrangedSubview(space)
        let returnKey = makeKey(title: "return") { [weak self] in self?.onAction?(.returnKey) }
        bottom.addArrangedSubview(returnKey)
        globeButton.widthAnchor.constraint(equalTo: returnKey.widthAnchor).isActive = true
        space.widthAnchor.constraint(equalTo: returnKey.widthAnchor, multiplier: 4).isActive = true
        stack.addArrangedSubview(bottom)

        probe.translatesAutoresizingMaskIntoConstraints = false
        addSubview(probe)
        addSubview(stack)
        NSLayoutConstraint.activate([
            probe.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            probe.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: probe.bottomAnchor, constant: 2),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            heightAnchor.constraint(equalToConstant: 230)
        ])
    }

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
