import RemoteKeyboardCore
import UIKit
import os

/// A tap and a key click on every key at touch down, at the levels the user chose (D23). The controller sets the flags
/// and levels through `KeyboardViewState` (`KeyFeedbackSettings`), so no view needs to know about the switches or Full
/// Access. With Full Access the click is played by `KeyClickPlayer` at the chosen volume; without it, or when the player
/// cannot start, it goes through `UIDevice.playInputClick()`, which plays only while the controller's input view
/// (`ClickableInputView`) adopts `UIInputViewAudioFeedback`. Both follow the iPhone silent switch.
@MainActor
enum KeyFeedback {
    static var isEnabled = false
    static var soundEnabled = false
    /// Play the click through `KeyClickPlayer` (Full Access); false uses the system click.
    static var customSound = false
    static var soundVolume = KeyFeedbackSettings.defaultSoundVolume
    static var hapticIntensity = KeyFeedbackSettings.defaultHapticIntensity
    private static let generator = UIImpactFeedbackGenerator(style: .medium)
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard", category: "feedback")
    /// The keyboard is on screen; only then may the click engine run.
    private static var isActive = false
    private static var loggedFallback = false

    /// Wakes the haptic engine and the click engine so the first press after a pause is not late.
    static func prepare() {
        if isEnabled, hapticIntensity > 0 { generator.prepare() }
        if isActive, soundEnabled, customSound, soundVolume > 0 { KeyClickPlayer.shared.prepare() }
    }

    /// The keyboard appeared (`viewDidAppear`): the only place, besides the Settings page, that forgets an earlier click
    /// engine failure.
    static func activate() {
        isActive = true
        loggedFallback = false
        if isEnabled, hapticIntensity > 0 { generator.prepare() }
        if soundEnabled, customSound, soundVolume > 0 { KeyClickPlayer.shared.begin() }
    }

    /// The keyboard went away: stop the click engine so nothing runs in the background.
    static func deactivate() {
        isActive = false
        KeyClickPlayer.shared.stop()
    }

    static func touchDown() {
        if soundEnabled { playClick() }
        guard isEnabled, hapticIntensity > 0 else { return }
        generator.impactOccurred(intensity: CGFloat(hapticIntensity))
        generator.prepare()
    }

    private static func playClick() {
        // Only while the keyboard is on screen: a late touch after `deactivate()` must not restart the engine.
        if customSound, isActive {
            if KeyClickPlayer.shared.play(volume: soundVolume) { return }
            if !loggedFallback {
                loggedFallback = true
                log.info("click fell back to the system click")
            }
        }
        UIDevice.current.playInputClick()
    }

    /// Settings preview: one click at `volume` (0…2).
    @discardableResult
    static func previewSound(volume: Double) -> Bool {
        let played = KeyClickPlayer.shared.play(volume: volume)
        log.info("sound preview, played \(played, privacy: .public)")
        return played
    }

    /// Settings preview: one tap at `intensity` (0…1).
    static func previewHaptic(intensity: Double) {
        guard intensity > 0 else { return }
        generator.impactOccurred(intensity: CGFloat(min(max(intensity, 0), 1)))
        log.info("haptic preview")
    }
}

/// Rollover for fast typing (D24): when a second character key goes down while the first is still held, the first is
/// sent at once, so characters leave in the order the keys went down. The bookkeeping is `KeyRolloverTracker`; this
/// only finds the key behind an id and sends it.
@MainActor
enum KeyRollover {
    private final class Weak {
        weak var key: KeyButton?
        init(_ key: KeyButton) { self.key = key }
    }

    private static var tracker = KeyRolloverTracker()
    private static var keys: [Int: Weak] = [:]
    private static var nextID = 0

    static func register(_ key: KeyButton) -> Int {
        nextID += 1
        // Keys that were deallocated (a rebuilt layout) leave an empty entry behind; clear them out once the table is large.
        if keys.count > 256 { keys = keys.filter { $0.value.key != nil } }
        keys[nextID] = Weak(key)
        return nextID
    }

    /// A rollover key went down: send the keys still waiting, in press order.
    static func touchDown(_ id: Int) {
        for waiting in tracker.touchDown(id) { keys[waiting]?.key?.send() }
    }

    static func touchUpInside(_ id: Int) -> Bool { tracker.touchUpInside(id) }
    static func cancel(_ id: Int) { tracker.cancel(id) }
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

    /// Letter and symbol keys set this: they take part in rollover (see `KeyRollover`). Keys that repeat (delete), and
    /// Shift, space and the other function keys, leave it off.
    var participatesInRollover = false {
        didSet { if participatesInRollover, rolloverID == nil { rolloverID = KeyRollover.register(self) } }
    }
    private var rolloverID: Int?

    /// No fill at rest (a key floating over other content); a light fill shows only while pressed.
    var isTransparent = false {
        didSet { updateBackground() }
    }

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
        // A press that ends outside the key or is cancelled sends nothing, also when it was waiting for rollover.
        addAction(UIAction { [weak self] _ in self?.cancelRollover() }, for: [.touchUpOutside, .touchCancel])
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
        if newWindow == nil {
            stopRepeating()
            cancelRollover()
        }
    }

    private func updateBackground() {
        let light = style == .letter || isOn
        let base: UIColor = light ? Self.letterColor : Self.functionColor
        let pressed: UIColor = light ? Self.functionColor : Self.letterColor
        if isTransparent {
            backgroundColor = isHighlighted ? .tertiarySystemFill : .clear
            return
        }
        backgroundColor = isHighlighted ? pressed : base
    }

    private func touchDown() {
        KeyFeedback.touchDown()
        if let rolloverID { KeyRollover.touchDown(rolloverID) }
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
        // A rollover key was already sent when the next key went down; then there is nothing left to send.
        if let rolloverID {
            if KeyRollover.touchUpInside(rolloverID) { onTap?() }
            return
        }
        // A repeating key already fired at touch down.
        if onRepeat == nil { onTap?() }
    }

    /// Sends the key as a release inside would (called by `KeyRollover` for a key that is still held).
    fileprivate func send() { onTap?() }

    private func cancelRollover() {
        if let rolloverID { KeyRollover.cancel(rolloverID) }
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
