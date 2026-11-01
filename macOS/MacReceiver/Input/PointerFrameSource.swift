import AppKit
import Foundation
import QuartzCore
import RemoteKeyboardCore

/// Calls `onFrame` once per screen refresh while it is running, with the frame's `timestamp` and `targetTimestamp` in
/// microseconds on the `PointerClock` timebase (the display link reports them in seconds on the same monotonic clock). The receiver starts it when cursor movement is waiting to be
/// played and stops it when the queue is empty, so nothing runs while the cursor is still. Tests drive it by hand.
@MainActor
protocol PointerFrameSource: AnyObject {
    var onFrame: ((_ timestampMicros: UInt64, _ targetMicros: UInt64) -> Void)? { get set }
    var isRunning: Bool { get }
    func start()
    func stop()
}

/// The product frame source: a display link of the screen the cursor is on (`NSScreen.displayLink`, macOS 14 and later), added
/// to the main run loop in the common modes. Without any screen to ask, a 120 Hz timer stands in so queued movement still plays.
@MainActor
final class DisplayLinkFrameSource: NSObject, PointerFrameSource {
    var onFrame: ((_ timestampMicros: UInt64, _ targetMicros: UInt64) -> Void)?
    private var link: CADisplayLink?
    private var fallback: Timer?

    var isRunning: Bool { link != nil || fallback != nil }

    func start() {
        guard !isRunning else { return }
        if let screen = Self.screenUnderCursor() {
            let link = screen.displayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            fallback = CommonModeTimer.make(1.0 / 120, repeats: true) { [weak self] in
                let now = PointerClock.nowMicros()
                self?.onFrame?(now, now + 8_333)
            }
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
        fallback?.invalidate()
        fallback = nil
    }

    @objc private func frame(_ link: CADisplayLink) {
        onFrame?(Self.micros(link.timestamp), Self.micros(link.targetTimestamp))
    }

    private static func micros(_ seconds: CFTimeInterval) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000)
    }

    private static func screenUnderCursor() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
