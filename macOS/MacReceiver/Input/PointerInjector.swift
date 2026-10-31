import CoreGraphics
import Foundation
import RemoteKeyboardCore

/// Posts the pointer actions as CGEvents (mouse move or drag, click, left button, pixel scroll). A thin adapter: what the
/// actions are is decided in Core, and nothing here is logged.
///
/// The cursor position is read from the system every time and added to; the part of a movement under one point is kept here
/// and used in the next one, unless the user moved the cursor some other way in between (then the system position wins).
@MainActor
final class PointerInjector: PointerOutput {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var carried: CGPoint?
    private var scrollRemainder = CGPoint.zero

    func apply(_ actions: [PointerAction]) {
        for action in actions { perform(action) }
    }

    private func perform(_ action: PointerAction) {
        switch action {
        case .move(let dx, let dy, let dragging):
            moveCursor(dx: dx, dy: dy, dragging: dragging)
        case .click(let count):
            let position = currentPosition()
            postMouse(.leftMouseDown, at: position, clickState: count)
            postMouse(.leftMouseUp, at: position, clickState: count)
        case .leftButton(let down):
            postMouse(down ? .leftMouseDown : .leftMouseUp, at: currentPosition(), clickState: 1)
        case .scroll(let dx, let dy, let phase):
            postScroll(dx: dx, dy: dy, phase: phase)
        }
    }

    // MARK: Cursor

    private func currentPosition() -> CGPoint {
        let actual = CGEvent(source: nil)?.location ?? carried ?? .zero
        if let carried, hypot(carried.x - actual.x, carried.y - actual.y) < 1.5 { return carried }
        return actual
    }

    private func moveCursor(dx: Double, dy: Double, dragging: Bool) {
        let from = currentPosition()
        let target = PointerScreenClamp.clamp(CGPoint(x: from.x + dx, y: from.y + dy), to: Self.screens())
        carried = target
        let deltaX = Int64(target.x.rounded() - from.x.rounded())
        let deltaY = Int64(target.y.rounded() - from.y.rounded())
        guard let event = CGEvent(
            mouseEventSource: source, mouseType: dragging ? .leftMouseDragged : .mouseMoved, mouseCursorPosition: target,
            mouseButton: .left)
        else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: deltaX)
        event.setIntegerValueField(.mouseEventDeltaY, value: deltaY)
        event.post(tap: .cghidEventTap)
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, clickState: Int) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        else { return }
        event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        event.post(tap: .cghidEventTap)
    }

    /// The union of the active displays, in the global space the cursor lives in.
    private static func screens() -> [CGRect] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    // MARK: Scroll

    /// Pixel scroll, content following the fingers: fingers down move the content down. The part of a movement under one pixel
    /// is carried into the next event.
    private func postScroll(dx: Double, dy: Double, phase: PointerPayload.ScrollPhase) {
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let wholeX = Int32(scrollRemainder.x.rounded(.towardZero))
        let wholeY = Int32(scrollRemainder.y.rounded(.towardZero))
        scrollRemainder.x -= Double(wholeX)
        scrollRemainder.y -= Double(wholeY)
        let ends = phase == .ended || phase == .cancelled
        if ends { scrollRemainder = .zero }
        guard wholeX != 0 || wholeY != 0 || ends || phase == .began else { return }
        guard let event = CGEvent(
            scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: wholeY, wheel2: wholeX, wheel3: 0)
        else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Self.phaseValue(phase))
        event.post(tap: .cghidEventTap)
    }

    /// `CGScrollPhase`: began 1, changed 2, ended 4, cancelled 8.
    static func phaseValue(_ phase: PointerPayload.ScrollPhase) -> Int64 {
        switch phase {
        case .began: 1
        case .changed: 2
        case .ended: 4
        case .cancelled: 8
        }
    }
}
