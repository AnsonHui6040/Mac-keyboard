#if DEBUG
import RemoteKeyboardCore
import UIKit

/// The M4 test surface (Debug builds only), laid over the keyboard. Each stroke's first `touchesMoved` turns the whole
/// surface white for a moment (T2) and hands a cursor probe to the runner at once (T3); while the finger keeps moving a probe
/// goes out every 16.7 ms. `coalescedTouches` add up the sideways distance, which is quantized to 1/16 pt only when the
/// probe is built, and the remainder stays for the next one. A probe the radio refuses keeps its distance for the next try.
/// The distance goes into the encrypted probe and nowhere else: it is not logged, not shown and not written to the CSV.
final class MeasurementTouchView: UIView {
    static let sendInterval: TimeInterval = 1.0 / 60
    static let flashSeconds: TimeInterval = 0.1

    private let runner: MeasurementRunner
    var onClose: (() -> Void)?

    private var tracked: UITouch?
    private var lastX: CGFloat = 0
    private var pendingDx = 0.0
    private var earliestSampleMicros: UInt64?
    private var firstProbePending = true
    private var sendTimer: Timer?
    private var flashTimer: Timer?
    private let hint = UILabel()
    private let closeButton = UIButton(type: .system)

    init(runner: MeasurementRunner) {
        self.runner = runner
        super.init(frame: .zero)
        backgroundColor = Self.idleColor
        isMultipleTouchEnabled = false
        accessibilityIdentifier = "rk.measure.touch"
        hint.text = "M4 觸控面：從靜止開始橫向滑動"
        hint.textColor = UIColor(white: 0.55, alpha: 1)
        hint.font = .systemFont(ofSize: 15)
        hint.textAlignment = .center
        hint.isUserInteractionEnabled = false
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        closeButton.setTitle("×", for: .normal)
        closeButton.titleLabel?.font = .systemFont(ofSize: 28, weight: .light)
        closeButton.tintColor = UIColor(white: 0.7, alpha: 1)
        closeButton.accessibilityIdentifier = "rk.measure.touch.close"
        closeButton.accessibilityLabel = "關閉 M4 觸控面"
        closeButton.addAction(UIAction { [weak self] _ in self?.onClose?() }, for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private static let idleColor = UIColor(white: 0.08, alpha: 1)

    /// Taken off the keyboard: the timers stop with it.
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard superview == nil else { return }
        sendTimer?.invalidate()
        sendTimer = nil
        flashTimer?.invalidate()
        flashTimer = nil
    }

    // MARK: Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard tracked == nil, let touch = touches.first else { return }
        tracked = touch
        lastX = touch.location(in: self).x
        pendingDx = 0
        earliestSampleMicros = nil
        firstProbePending = true
        startSending()
        flashPending = true
    }

    /// The flash waits for the first movement, not the first contact.
    private var flashPending = false

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = tracked, touches.contains(touch) else { return }
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            let x = sample.location(in: self).x
            let step = Double(x - lastX)
            lastX = x
            guard step != 0 else { continue }
            pendingDx += step
            if earliestSampleMicros == nil { earliestSampleMicros = UInt64(sample.timestamp * 1_000_000) }
        }
        guard pendingDx != 0 else { return }
        if flashPending {
            flashPending = false
            flash()
        }
        if firstProbePending { sendPending() }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { endStroke(touches) }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { endStroke(touches) }

    private func endStroke(_ touches: Set<UITouch>) {
        guard let touch = tracked, touches.contains(touch) else { return }
        sendPending()
        tracked = nil
        sendTimer?.invalidate()
        sendTimer = nil
    }

    // MARK: Probes

    private func startSending() {
        sendTimer?.invalidate()
        let timer = Timer(timeInterval: Self.sendInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendPending() }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        sendTimer = timer
    }

    private func sendPending() {
        let sixteenths = Int((pendingDx * 16).rounded())
        guard sixteenths != 0 else { return }
        let chunk = Int16(clamping: sixteenths)
        let sample = earliestSampleMicros ?? MeasureClock.nowMicros()
        guard runner.sendCursor(dxSixteenths: chunk, sampleMicros: sample, isFirstOfStroke: firstProbePending) else { return }
        firstProbePending = false
        pendingDx -= Double(chunk) / 16
        earliestSampleMicros = pendingDx == 0 ? nil : MeasureClock.nowMicros()
    }

    // MARK: Flash

    private func flash() {
        backgroundColor = .white
        hint.isHidden = true
        flashTimer?.invalidate()
        let timer = Timer(timeInterval: Self.flashSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.backgroundColor = Self.idleColor
                self?.hint.isHidden = false
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        flashTimer = timer
    }
}
#endif
