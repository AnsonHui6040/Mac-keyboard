import RemoteKeyboardCore
import UIKit

/// The touchpad page's controller: it owns the gesture machine, feeds the peripheral's `PointerSender` and keeps the page and
/// the Mac's channel in step (opens it on entering, releases and closes it on leaving, asks again after a reconnect).
///
/// Fingers are read by the page view; `TrackpadGesture` turns them into clicks, drags, moves and scrolls; this class hands
/// those to the sender and pumps the peripheral. Nothing here logs or stores a position.
@MainActor
final class TrackpadCoordinator {
    private let peripheral: KeyboardBLEPeripheral
    private var gesture = TrackpadGesture()
    private(set) var isActive = false
    /// Multiplier on one-finger cursor motion (`TrackpadSensitivity`); scroll and the gesture thresholds are not scaled.
    var sensitivity = TrackpadSensitivity.defaultValue
    /// Most cursor packets per second, or 自動 (`TrackpadSendRate`); the sender is paced by it.
    var sendRate = TrackpadSendRate.defaultValue {
        didSet { peripheral.pointerSendRate = sendRate }
    }
    /// The page's state may have changed (the channel opened, was refused, or the link dropped).
    var onChange: (() -> Void)?

    init(peripheral: KeyboardBLEPeripheral) {
        self.peripheral = peripheral
        peripheral.pointerSendRate = sendRate
    }

    /// The line to draw on the page, or nil when it takes touches.
    var message: String? { TrackpadPage.message(for: peripheral.pointerAvailability) }

    // MARK: Page

    func enter() {
        guard !isActive else { return }
        isActive = true
        gesture = TrackpadGesture()
        peripheral.onPointerChange = { [weak self] in self?.channelChanged() }
        peripheral.openPointer()
        onChange?()
    }

    /// The page is left (or the keyboard goes away): what is held is released, then the Mac is told.
    func leave() {
        guard isActive else { return }
        isActive = false
        gesture = TrackpadGesture()
        peripheral.closePointer()
        peripheral.onPointerChange = nil
        onChange?()
    }

    /// The link or the Mac's status changed; ask again when the channel is not open yet.
    func refresh() {
        guard isActive else { return }
        peripheral.openPointer()
    }

    private func channelChanged() {
        // A gesture that was going on belongs to the channel that ended.
        if peripheral.pointerState != .open { gesture = TrackpadGesture() }
        onChange?()
    }

    // MARK: Touches

    func touchesBegan(_ touches: [TrackpadTouch]) { feed(gesture.touchesBegan(touches)) }
    func touchesMoved(_ touches: [TrackpadTouch]) { feed(gesture.touchesMoved(touches)) }
    func touchesEnded(_ touches: [TrackpadTouch]) { feed(gesture.touchesEnded(touches)) }

    func touchesCancelled(atMicros time: UInt64) {
        feed(gesture.touchesCancelled(atMicros: time))
        // A cancel also lets go of anything the sender still holds.
        peripheral.pointerSender?.releaseAll(atMicros: time)
        peripheral.pumpPointer()
    }

    func tick(nowMicros now: UInt64) {
        guard isActive else { return }
        peripheral.pointerSender?.rate = sendRate
        feed(gesture.tick(nowMicros: now))
        // Pacing, the heartbeat and anything the radio refused earlier are worked on every refresh.
        peripheral.pumpPointer()
    }

    private func feed(_ outputs: [TrackpadOutput]) {
        guard peripheral.pointerState == .open, let sender = peripheral.pointerSender else { return }
        sender.rate = sendRate
        for output in outputs {
            switch output {
            case .strokeBegan(let t): sender.strokeBegan(atMicros: t)
            case .move(let dx, let dy, let t):
                let scaled = TrackpadSensitivity.scaled(dx: dx, dy: dy, by: sensitivity)
                sender.addMove(dx: scaled.dx, dy: scaled.dy, atMicros: t)
            case .click(let count, let t): sender.click(count: count, atMicros: t)
            case .rightClick(let t): sender.rightClick(atMicros: t)
            case .buttonDown(let t): sender.setLeftButton(true, atMicros: t)
            case .buttonUp(let t): sender.setLeftButton(false, atMicros: t)
            case .scrollBegan(let t): sender.scrollBegan(atMicros: t)
            case .scroll(let dx, let dy, let t): sender.addScroll(dx: dx, dy: dy, atMicros: t)
            case .scrollEnded(let t): sender.scrollEnded(atMicros: t)
            }
        }
        peripheral.pumpPointer()
    }
}

