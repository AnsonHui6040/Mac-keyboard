import QuartzCore
import RemoteKeyboardCore
import UIKit

/// What the touchpad page needs to draw: the line shown on it (nil when it takes touches).
struct TrackpadPageState: Equatable {
    var message: String?
}

/// The touchpad page: a light grey surface over the whole key area. It only reports finger samples (in points of this view,
/// on the clock of `PointerClock`) and a regular tick; what they mean is decided by `TrackpadGesture` in Core, behind the
/// controller. While `message` is set the surface takes no touches and shows the line instead.
///
/// The view itself is a (nearly) transparent surface with the grey drawn on a non-interactive subview, so the touches of the
/// 3 pt edge also land here (D24: a fully transparent pixel of a keyboard extension gets no touch).
final class TrackpadPageView: UIView {
    /// A bar that takes the touches on it without passing them on to the pad behind (a plain view would forward them).
    private final class BarView: UIView {
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {}
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {}
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {}
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {}
    }

    private static let barHeight: CGFloat = 36

    var onTouchesBegan: (([TrackpadTouch]) -> Void)?
    var onTouchesMoved: (([TrackpadTouch]) -> Void)?
    var onTouchesEnded: (([TrackpadTouch]) -> Void)?
    var onTouchesCancelled: ((UInt64) -> Void)?
    /// Once per display refresh while the page is shown; drives the long press, the pacing and the heartbeat.
    var onTick: ((UInt64) -> Void)?
    /// The cursor-speed multiplier changed (also called once by the owner to read the stored value).
    var onSensitivityChange: ((Double) -> Void)?

    private(set) var sensitivity: Double = TrackpadSensitivity.clamped(
        UserDefaults.standard.object(forKey: TrackpadSensitivity.defaultsKey) as? Double)

    private let surface = UIView()
    private let label = UILabel()
    private let bar = BarView()
    private let valueLabel = UILabel()
    private var ids: [ObjectIdentifier: Int] = [:]
    private var nextID = 0
    private var displayLink: CADisplayLink?
    private var message: String?

    private var acceptsTouches: Bool { message == nil }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .keyboardTouchSurface
        isMultipleTouchEnabled = true
        accessibilityIdentifier = "rk.trackpad.state"
        accessibilityLabel = "觸控板"
        // The pad's state is readable from outside the process: `ready`, or `blocked` while a line is shown on it.
        isAccessibilityElement = true
        accessibilityTraits = .allowsDirectInteraction
        accessibilityValue = "blocked"

        surface.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 0.20, alpha: 1) : UIColor(white: 0.86, alpha: 1)
        }
        surface.layer.cornerRadius = 8
        surface.isUserInteractionEnabled = false
        addSubview(surface)

        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 2
        label.isUserInteractionEnabled = false
        label.accessibilityIdentifier = "rk.trackpad.message"
        addSubview(label)
        label.isHidden = true

        setUpBar()
    }

    private func setUpBar() {
        bar.backgroundColor = .keyboardTouchSurface
        bar.accessibilityIdentifier = "rk.trackpad.sensitivityBar"
        addSubview(bar)

        let title = UILabel()
        title.text = "靈敏度"
        title.font = .systemFont(ofSize: 14)
        title.textColor = .secondaryLabel

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 16, weight: .medium)
        valueLabel.textColor = .label
        valueLabel.textAlignment = .center
        valueLabel.accessibilityIdentifier = "rk.trackpad.sensitivityValue"
        valueLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true

        let stack = UIStackView(arrangedSubviews: [
            title, stepButton("−", steps: -1, id: "rk.trackpad.sensitivityDown"), valueLabel,
            stepButton("＋", steps: 1, id: "rk.trackpad.sensitivityUp"),
        ])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ])
        valueLabel.text = TrackpadSensitivity.displayText(sensitivity)
    }

    private func stepButton(_ title: String, steps: Int, id: String) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.attributedTitle = AttributedString(
            title, attributes: AttributeContainer([.font: UIFont.systemFont(ofSize: 20, weight: .medium)]))
        configuration.baseForegroundColor = .label
        configuration.background.cornerRadius = 6
        configuration.background.backgroundColor = .tertiarySystemFill
        let button = UIButton(configuration: configuration)
        button.accessibilityIdentifier = id
        button.accessibilityLabel = steps < 0 ? "降低靈敏度" : "提高靈敏度"
        button.addAction(UIAction { _ in KeyFeedback.touchDown() }, for: .touchDown)
        button.addAction(UIAction { [weak self] _ in self?.step(steps) }, for: .touchUpInside)
        button.widthAnchor.constraint(equalToConstant: 48).isActive = true
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }

    private func step(_ steps: Int) {
        sensitivity = TrackpadSensitivity.stepped(sensitivity, by: steps)
        UserDefaults.standard.set(sensitivity, forKey: TrackpadSensitivity.defaultsKey)
        valueLabel.text = TrackpadSensitivity.displayText(sensitivity)
        onSensitivityChange?(sensitivity)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ state: TrackpadPageState) {
        if message != state.message {
            message = state.message
            label.text = state.message
            label.isHidden = state.message == nil
            // Fingers that were down when the channel went away mean nothing to the next one.
            ids.removeAll()
        }
        accessibilityValue = state.message == nil ? "ready" : "blocked"
        updateDisplayLink()
    }

    override var isHidden: Bool {
        didSet { updateDisplayLink() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDisplayLink()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        bar.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.barHeight)
        let area = bounds.insetBy(dx: KeyboardMetrics.keyAreaSideInset, dy: KeyboardMetrics.keyAreaVerticalInset)
        let top = max(area.minY, Self.barHeight)
        surface.frame = CGRect(x: area.minX, y: top, width: area.width, height: max(0, area.maxY - top))
        label.frame = surface.frame.insetBy(dx: 16, dy: 8)
    }

    // MARK: Display link

    @MainActor
    private final class LinkTarget {
        weak var owner: TrackpadPageView?
        @objc func fire(_ link: CADisplayLink) { owner?.tick() }
    }

    private func updateDisplayLink() {
        let wanted = window != nil && !isHidden
        if wanted, displayLink == nil {
            let target = LinkTarget()
            target.owner = self
            let link = CADisplayLink(target: target, selector: #selector(LinkTarget.fire(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            displayLink = link
        } else if !wanted, let link = displayLink {
            link.invalidate()
            displayLink = nil
        }
    }

    private func tick() {
        onTick?(PointerClock.nowMicros())
    }

    // MARK: Touches

    private func sample(_ touch: UITouch, at location: CGPoint? = nil, time: TimeInterval? = nil) -> TrackpadTouch? {
        guard let id = ids[ObjectIdentifier(touch)] else { return nil }
        let point = location ?? touch.location(in: self)
        return TrackpadTouch(
            id: id, x: Double(point.x), y: Double(point.y), timeMicros: UInt64(max(0, time ?? touch.timestamp) * 1_000_000))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsTouches else { return }
        var samples: [TrackpadTouch] = []
        for touch in touches {
            nextID += 1
            ids[ObjectIdentifier(touch)] = nextID
            if let s = sample(touch) { samples.append(s) }
        }
        onTouchesBegan?(samples)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsTouches else { return }
        var samples: [TrackpadTouch] = []
        for touch in touches {
            // Every coalesced sample is used, so the cursor follows the finger's real path and speed.
            let all = event?.coalescedTouches(for: touch) ?? [touch]
            for coalesced in all {
                if let s = sample(touch, at: coalesced.location(in: self), time: coalesced.timestamp) { samples.append(s) }
            }
        }
        // With two fingers the samples of both are taken in time order, so the centre of a scroll moves evenly.
        let ordered = samples.enumerated().sorted {
            ($0.element.timeMicros, $0.offset) < ($1.element.timeMicros, $1.offset)
        }.map(\.element)
        if !ordered.isEmpty { onTouchesMoved?(ordered) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        var samples: [TrackpadTouch] = []
        for touch in touches {
            if let s = sample(touch) { samples.append(s) }
            ids[ObjectIdentifier(touch)] = nil
        }
        if !samples.isEmpty { onTouchesEnded?(samples) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches { ids[ObjectIdentifier(touch)] = nil }
        onTouchesCancelled?(PointerClock.nowMicros())
    }

    /// The keyboard goes away or the page is left with fingers down: no touch-up will come.
    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil, !ids.isEmpty {
            ids.removeAll()
            onTouchesCancelled?(PointerClock.nowMicros())
        }
    }
}
