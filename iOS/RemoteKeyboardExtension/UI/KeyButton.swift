import UIKit

/// One key. Letter keys are light, function keys darker, an active function key (Shift on) turns light.
/// Plain system colours and fonts only; nothing is copied from Apple's keyboard assets.
final class KeyButton: UIButton {
    enum Style {
        case letter
        case function
    }

    /// Called on touch up inside.
    var onTap: (() -> Void)?
    /// When set, the key fires at touch down and then repeats while held: after 0.5 s, then every 0.1 s.
    var onRepeat: (() -> Void)?

    private let style: Style
    private var repeatTask: Task<Void, Never>?
    private var isOn = false

    init(style: Style, title: String? = nil, symbol: String? = nil, label: String, identifier: String? = nil) {
        self.style = style
        super.init(frame: .zero)
        accessibilityLabel = label
        accessibilityIdentifier = identifier
        titleLabel?.font = .systemFont(ofSize: style == .letter ? 22 : 15)
        titleLabel?.adjustsFontSizeToFitWidth = true
        titleLabel?.minimumScaleFactor = 0.7
        setTitleColor(.label, for: .normal)
        setTitleColor(.tertiaryLabel, for: .disabled)
        tintColor = .label
        layer.cornerRadius = 6
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 0
        layer.shadowOffset = CGSize(width: 0, height: 1)
        if let title { setTitle(title, for: .normal) }
        if let symbol { setSymbol(symbol) }
        updateBackground()
        addAction(UIAction { [weak self] _ in self?.touchUp() }, for: .touchUpInside)
        addAction(UIAction { [weak self] _ in self?.touchDown() }, for: .touchDown)
        addAction(
            UIAction { [weak self] _ in self?.stopRepeating() },
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { repeatTask?.cancel() }

    func setSymbol(_ name: String) {
        let configuration = UIImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        setImage(UIImage(systemName: name, withConfiguration: configuration), for: .normal)
    }

    /// An active function key (Shift once or locked) is drawn like a letter key.
    func setOn(_ on: Bool) {
        isOn = on
        updateBackground()
    }

    override var isHighlighted: Bool {
        didSet { updateBackground() }
    }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1 : 0.45
            updateBackground()
        }
    }

    private func updateBackground() {
        let light = style == .letter || isOn
        let base: UIColor = light ? Self.letterColor : Self.functionColor
        let pressed: UIColor = light ? Self.functionColor : Self.letterColor
        backgroundColor = isHighlighted ? pressed : base
    }

    private func touchDown() {
        guard let onRepeat else { return }
        onRepeat()
        repeatTask?.cancel()
        repeatTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            while !Task.isCancelled {
                self?.onRepeat?()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func touchUp() {
        // A repeating key already fired at touch down.
        if onRepeat == nil { onTap?() }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }

    private static let letterColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white
    }
    private static let functionColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.26, alpha: 1) : UIColor(red: 0.68, green: 0.70, blue: 0.74, alpha: 1)
    }
}

/// Lays key frames out in one row. Shared by the letter, symbol and bottom rows.
enum KeyRowLayout {
    /// `count` equal keys across `width`, starting at `x`.
    static func equalKeys(count: Int, x: Double, width: Double, gap: Double) -> [(x: Double, width: Double)] {
        guard count > 0 else { return [] }
        let key = (width - Double(count - 1) * gap) / Double(count)
        return (0..<count).map { (x + Double($0) * (key + gap), key) }
    }
}
