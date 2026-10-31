import UIKit

/// A light tap and the system key click on every key at touch down. The controller sets both flags through
/// `KeyboardViewState` (`KeyFeedbackSettings`), so no view needs to know about the switches or Full Access. The click
/// goes through `UIDevice.playInputClick()`, which plays only while the controller's input view
/// (`ClickableInputView`) adopts `UIInputViewAudioFeedback`, so the iPhone silent switch and the system keyboard feedback setting
/// still decide whether it is heard.
@MainActor
enum KeyFeedback {
    static var isEnabled = false
    static var soundEnabled = false
    private static let generator = UIImpactFeedbackGenerator(style: .light)

    /// Wakes the haptic engine so the first press after a pause is not late.
    static func prepare() {
        guard isEnabled else { return }
        generator.prepare()
    }

    static func touchDown() {
        if soundEnabled { UIDevice.current.playInputClick() }
        guard isEnabled else { return }
        generator.impactOccurred()
        generator.prepare()
    }
}

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
    /// Asked at touch down, before the first fire: false means this press fires once and does not repeat.
    var allowsRepeat: (() -> Bool)?

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
        didSet { updateBackground() }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        // The keyboard can go away mid-press (no touch-up arrives), so a held key must not keep repeating.
        if newWindow == nil { stopRepeating() }
    }

    private func updateBackground() {
        let light = style == .letter || isOn
        let base: UIColor = light ? Self.letterColor : Self.functionColor
        let pressed: UIColor = light ? Self.functionColor : Self.letterColor
        backgroundColor = isHighlighted ? pressed : base
    }

    private func touchDown() {
        KeyFeedback.touchDown()
        guard let onRepeat else { return }
        let repeats = allowsRepeat?() ?? true
        onRepeat()
        guard repeats else { return }
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
