#if DEBUG
import AppKit
import CoreGraphics

/// A small borderless window in the top-left corner of the main screen that turns white for a moment when a cursor probe
/// arrives (T5′ of the M4 measurement). It exists only while measurement mode is on, never takes a click and never takes
/// the focus. White time is short and restarts on every probe, so a stream of probes keeps it white.
@MainActor
final class MeasureFlashWindow: MeasureFlashing {
    static let side: CGFloat = 120
    static let litSeconds: TimeInterval = 0.05

    private var window: NSWindow?
    private var timer: Timer?
    private(set) var isLit = false

    func setActive(_ active: Bool) {
        if active { show() } else { hide() }
    }

    func show() {
        guard window == nil else { return }
        let frame = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let rect = NSRect(x: frame.minX, y: frame.maxY - Self.side, width: Self.side, height: Self.side)
        let window = NSWindow(contentRect: rect, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.isOpaque = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.backgroundColor = .black
        window.orderFrontRegardless()
        self.window = window
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        isLit = false
        window?.orderOut(nil)
        window = nil
    }

    func flash() {
        guard let window else { return }
        window.backgroundColor = .white
        isLit = true
        timer?.invalidate()
        timer = CommonModeTimer.make(Self.litSeconds, repeats: false) { [weak self] in
            self?.window?.backgroundColor = .black
            self?.isLit = false
        }
    }
}

/// Moves the mouse cursor sideways for the M4 measurement: the current position plus `dx`, kept inside the displays.
/// Posting needs the Accessibility permission the Receiver already holds for typing.
@MainActor
final class MeasureCursorMover: MeasureCursorMoving {
    func move(byPoints dx: Double) {
        guard dx != 0, let start = CGEvent(source: nil)?.location else { return }
        let bounds = Self.displayBounds()
        let x = min(max(start.x + dx, bounds.minX), bounds.maxX - 1)
        let point = CGPoint(x: x, y: start.y)
        guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)
        else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
        event.post(tap: .cghidEventTap)
    }

    /// The union of all active displays in Quartz coordinates.
    private static func displayBounds() -> CGRect {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).reduce(CGRect.null) { $0.union(CGDisplayBounds($1)) }
    }
}
#endif
