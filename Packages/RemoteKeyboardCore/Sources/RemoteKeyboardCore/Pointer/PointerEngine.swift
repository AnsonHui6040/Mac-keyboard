import Foundation

/// What the Mac does for a packet, in terms the CGEvent adapter understands. Distances are in Mac points.
public enum PointerAction: Equatable, Sendable {
    /// Move the cursor by this much (already scaled by the speed curve). `dragging` posts a drag event instead of a move.
    case move(dx: Double, dy: Double, dragging: Bool)
    case click(count: Int)
    case rightClick
    case leftButton(down: Bool)
    case scroll(dx: Double, dy: Double, phase: PointerPayload.ScrollPhase)
}

/// The Mac side of the pointer protocol, as a pure state machine (trackpad spec §6.4, §10; MVP subset). It is handed packets
/// that already passed authentication, the replay window and `PointerPayload.decode`, and returns what to do.
///
/// - The left button follows the `buttons` of the newest `buttonSeq` seen (RFC 1982 order). A packet with the same or an older
///   `buttonSeq` never changes it, so a late heartbeat or a repeated old state cannot press or release anything.
/// - Every valid packet restarts the watchdog: a held button is released 350 ms after the last one, a scroll is ended after
///   150 ms. After a watchdog release the `buttonSeq` stays, so only a newer one presses again.
/// - `reset` releases everything (the channel closed, the link dropped, the switch went off).
///
/// Time is passed in. Nothing here logs.
public struct PointerEngine: Sendable {
    public static let buttonWatchdogMicros: UInt64 = 350_000
    public static let scrollWatchdogMicros: UInt64 = 150_000

    public private(set) var leftDown = false
    public private(set) var isScrolling = false
    private var lastButtonSeq: UInt16?
    private var lastPacketAt: UInt64 = 0

    public init() {}

    /// The watchdog timer has something to watch.
    public var needsWatchdog: Bool { leftDown || isScrolling }

    public mutating func handle(_ payload: PointerPayload, nowMicros now: UInt64) -> [PointerAction] {
        lastPacketAt = now
        var actions: [PointerAction] = []
        applyButtons(of: payload, into: &actions)
        switch payload.opcode {
        case .move:
            guard payload.dx != 0 || payload.dy != 0 else { break }
            let scaled = PointerAcceleration.scaled(dxSixteenths: payload.dx, dySixteenths: payload.dy, dtTenthsOfMs: payload.dt)
            actions.append(.move(dx: scaled.dx, dy: scaled.dy, dragging: leftDown))
        case .scroll:
            scroll(payload, into: &actions)
        case .click:
            // Not in the middle of a drag.
            guard !leftDown else { break }
            switch payload.clickButton {
            case 0: actions.append(.click(count: payload.clickCount))
            case 1: actions.append(.rightClick)
            default: break
            }
        case .buttonState, .heartbeat:
            break
        }
        return actions
    }

    /// Called regularly while `needsWatchdog`.
    public mutating func watchdog(nowMicros now: UInt64) -> [PointerAction] {
        var actions: [PointerAction] = []
        if leftDown, now &- lastPacketAt >= Self.buttonWatchdogMicros {
            leftDown = false
            actions.append(.leftButton(down: false))
        }
        if isScrolling, now &- lastPacketAt >= Self.scrollWatchdogMicros {
            isScrolling = false
            actions.append(.scroll(dx: 0, dy: 0, phase: .ended))
        }
        return actions
    }

    /// The channel is over: release what is held and forget the button history, so a new session starts from nothing.
    public mutating func reset() -> [PointerAction] {
        var actions: [PointerAction] = []
        if leftDown { actions.append(.leftButton(down: false)) }
        if isScrolling { actions.append(.scroll(dx: 0, dy: 0, phase: .ended)) }
        self = PointerEngine()
        return actions
    }

    private mutating func applyButtons(of payload: PointerPayload, into actions: inout [PointerAction]) {
        if let last = lastButtonSeq, !isNewerButtonSeq(payload.buttonSeq, than: last) { return }
        lastButtonSeq = payload.buttonSeq
        let wantsDown = payload.leftDown
        guard wantsDown != leftDown else { return }
        leftDown = wantsDown
        actions.append(.leftButton(down: wantsDown))
    }

    private mutating func scroll(_ payload: PointerPayload, into actions: inout [PointerAction]) {
        let dx = Double(payload.dx) / 16, dy = Double(payload.dy) / 16
        switch payload.scrollPhase {
        case .began?, .changed?:
            // A `changed` with no `began` before it starts the scroll.
            let phase: PointerPayload.ScrollPhase = isScrolling ? .changed : .began
            isScrolling = true
            actions.append(.scroll(dx: dx, dy: dy, phase: phase))
        case .ended?, .cancelled?:
            guard isScrolling else { return }
            isScrolling = false
            actions.append(.scroll(dx: 0, dy: 0, phase: .ended))
        case nil:
            break
        }
    }
}
