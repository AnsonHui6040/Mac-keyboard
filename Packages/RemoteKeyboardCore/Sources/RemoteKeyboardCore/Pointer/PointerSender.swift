import Foundation

/// The iPhone's single ordered exit for `0x03` packets (trackpad spec §8, MVP subset).
///
/// Finger movement is added up and only leaves as quantized MOVE or SCROLL packets, at most `rate` per second; whatever is left of a division by 1/16 point stays for the next packet. Anything that changes what a
/// position means (a click, a button going down or up, the end of a scroll) first **closes** the movement before it into a
/// packet of its own, so the order on the wire is always: movement before the click, the click, movement after it. Closed
/// packets are handed out at once and in order; the open accumulation waits for its credit. A held button adds a HEARTBEAT
/// every `heartbeatIntervalMicros`.
///
/// The rate is kept by a **token bucket**: every `peek` adds `rate × elapsed` of credit (a rest never becomes more than a packet or
/// two), an open MOVE or SCROLL needs 1 and spends it. A display tick that is a little early or late therefore
/// does not change the average (in 自動 there is no limit: every `peek` with movement and a free radio gets a packet, which
/// is how a mouse works: one report per connection event): at 90 per second on a 120 Hz tick, three of every four ticks send. The first movement after a
/// rest goes at once.
///
/// The adapter asks `peek` for the next packet, seals and writes it, and then calls `handedOff` when the radio took it, or
/// `refused` when it did not. While refused (`isBlocked`) no packet is formed and the movement keeps adding up, so the first
/// packet after the radio is ready again carries all of it. There is no acknowledgement and no resend in this version: the
/// button state is kept right by the `buttons` and `buttonSeq` every packet carries, the heartbeat and the Mac's watchdog.
///
/// Time is always passed in (`PointerClock.nowMicros()`, the same clock as the touches). Single serial context only; no lock.
/// Nothing here is logged.
public final class PointerSender {
    /// One interval at the default 60 packets per second.
    public static let moveIntervalMicros: UInt64 = 16_667
    public static let heartbeatIntervalMicros: UInt64 = 100_000
    /// One displacement is split into at most this many packets; what does not fit is dropped and flagged as truncated.
    static let maxSplit = 8

    private struct Axis {
        var x = 0.0
        var y = 0.0
        /// When the displacement in `x`, `y` started and when its last sample was taken.
        var anchor: UInt64?
        var last: UInt64?

        mutating func add(_ dx: Double, _ dy: Double, at time: UInt64) {
            x += dx
            y += dy
            if anchor == nil { anchor = time }
            last = max(last ?? time, time)
        }

        var sixteenths: (x: Int, y: Int) { (Self.round16(x), Self.round16(y)) }

        /// In 1/16 point, kept far inside `Int` however large the sum got.
        private static func round16(_ value: Double) -> Int {
            Int(min(max((value * 16).rounded(), -1e9), 1e9))
        }
        var hasPacket: Bool { sixteenths != (0, 0) }

        /// Takes at most one packet's worth, leaving the remainder (and the part that did not fit in `Int16`).
        mutating func take() -> (dx: Int16, dy: Int16, dt: UInt16) {
            let q = sixteenths
            let dx = Int16(clamping: q.x), dy = Int16(clamping: q.y)
            x -= Double(dx) / 16
            y -= Double(dy) / 16
            let span = (last ?? 0) &- (anchor ?? last ?? 0)
            let tenths = UInt16(clamping: span / 100)
            // The time of this packet is used up; what is left starts from the last sample.
            anchor = last
            return (dx, dy, tenths)
        }

        mutating func clear() {
            x = 0
            y = 0
            anchor = nil
            last = nil
        }
    }

    private enum Offered {
        case closed
        case heartbeat
        case openMove
        case openScroll
    }

    /// Most open MOVE or SCROLL packets per second (`TrackpadSendRate`); `TrackpadSendRate.automatic` (0) has no limit: a packet
    /// is formed whenever the radio is not blocked and there is movement, so the radio sets the pace. A new sender uses 60.
    public var rate: Int = 60

    private var closed: [PointerPayload] = []
    private var move = Axis()
    private var scroll = Axis()
    private var offered: Offered?

    public private(set) var isLeftDown = false
    public private(set) var buttonSeq: UInt16
    public private(set) var isScrolling = false
    public private(set) var isBlocked = false
    private var scrollBeganSent = false
    private var afterBlock = false
    private var lastOpenSentAt: UInt64?
    /// Credit for open packets, 0…2, and the time it was last brought up to date.
    private var credit = 1.0
    private var creditAt: UInt64?
    private var lastHeartbeatAt: UInt64 = 0

    /// - Parameter rate: the rate to start with, so a session in 自動 is not limited before the first tick sets it.
    public init(startingButtonSeq: UInt16 = 0, rate: Int = 60) {
        buttonSeq = startingButtonSeq
        self.rate = rate
    }

    private var buttons: UInt8 { isLeftDown ? PointerPayload.leftButtonBit : 0 }

    // MARK: Input

    /// A finger touched down. Time is counted from here, so the first movement has a span to be a speed over.
    public func strokeBegan(atMicros time: UInt64) {
        // Movement of the stroke before is not mixed with this one; only a remainder under 1/16 point is let go.
        closeMoves()
        move.clear()
        move.anchor = time
        move.last = time
    }

    /// Finger movement in iPhone points since the last call (the gesture machine's `move`).
    public func addMove(dx: Double, dy: Double, atMicros time: UInt64) {
        move.add(dx, dy, at: time)
    }

    /// A left click; `count` 2 is the second click of a double click.
    public func click(count: Int = 1, atMicros time: UInt64) {
        closeMoves()
        closed.append(payload(.click, arg: PointerPayload.clickArg(count: count)))
    }

    public func rightClick(atMicros time: UInt64) {
        closeMoves()
        closed.append(payload(.click, arg: PointerPayload.clickArg(button: 1, count: 1)))
    }

    /// Presses or releases the left button. A repeat of the state it already has is nothing.
    public func setLeftButton(_ down: Bool, atMicros time: UInt64) {
        guard down != isLeftDown else { return }
        closeMoves()
        isLeftDown = down
        buttonSeq &+= 1
        if down { lastHeartbeatAt = time }
        closed.append(payload(.buttonState))
    }

    public func scrollBegan(atMicros time: UInt64) {
        guard !isScrolling else { return }
        closeMoves()
        isScrolling = true
        scrollBeganSent = false
        scroll.clear()
    }

    public func addScroll(dx: Double, dy: Double, atMicros time: UInt64) {
        guard isScrolling else { return }
        scroll.add(dx, dy, at: time)
    }

    public func scrollEnded(atMicros time: UInt64) {
        guard isScrolling else { return }
        closeScroll()
        // An end is always preceded by a began, even when the fingers never moved enough to produce one.
        if !scrollBeganSent {
            closed.append(scrollPayload(.began, dx: 0, dy: 0, dt: 0))
            scrollBeganSent = true
        }
        closed.append(scrollPayload(.ended, dx: 0, dy: 0, dt: 0))
        isScrolling = false
        scrollBeganSent = false
    }

    /// A touch was cancelled, the page was left or the keyboard went away: movement is flushed, the button is released and a
    /// scroll in progress is ended.
    public func releaseAll(atMicros time: UInt64) {
        closeMoves()
        if isScrolling { scrollEnded(atMicros: time) }
        setLeftButton(false, atMicros: time)
    }

    // MARK: Output

    /// The next packet to send, or `nil`. Nothing changes until `handedOff`.
    public func peek(nowMicros now: UInt64) -> PointerPayload? {
        offered = nil
        accrueCredit(to: now)
        guard !isBlocked else { return nil }
        if let first = closed.first {
            offered = .closed
            return first
        }
        if isLeftDown, now &- lastHeartbeatAt >= Self.heartbeatIntervalMicros {
            offered = .heartbeat
            return payload(.heartbeat)
        }
        guard TrackpadSendRate.isAutomatic(rate) || lastOpenSentAt == nil || credit >= Self.creditNeeded else { return nil }
        if isScrolling, scroll.hasPacket {
            offered = .openScroll
            var copy = scroll
            let taken = copy.take()
            return scrollPayload(scrollBeganSent ? .changed : .began, dx: taken.dx, dy: taken.dy, dt: taken.dt)
        }
        if !isScrolling, move.hasPacket {
            offered = .openMove
            var copy = move
            let taken = copy.take()
            return payload(
                .move, dx: taken.dx, dy: taken.dy, dt: taken.dt, status: afterBlock ? PointerPayload.statusAfterBlock : 0)
        }
        return nil
    }

    /// The radio took the packet `peek` returned last.
    public func handedOff(nowMicros now: UInt64) {
        defer { offered = nil }
        switch offered {
        case .closed?:
            let sent = closed.removeFirst()
            if sent.opcode == .move || sent.opcode == .scroll {
                spendCredit(at: now)
                if sent.opcode == .move { afterBlock = false }
            }
        case .heartbeat?:
            lastHeartbeatAt = now
        case .openMove?:
            _ = move.take()
            spendCredit(at: now)
            afterBlock = false
        case .openScroll?:
            _ = scroll.take()
            scrollBeganSent = true
            spendCredit(at: now)
        case nil:
            break
        }
    }

    /// Slightly under 1, so floating point rounding never costs a packet.
    private static let creditNeeded = 1.0 - 1e-9

    private func accrueCredit(to now: UInt64) {
        defer { creditAt = now }
        guard let before = creditAt, now > before else { return }
        // One look adds at most one packet's worth. The credit stops at 1, except in steady streaming (the last open packet went
        // within two intervals) while movement waits: there it may run up to 2, so a tick a little late does not throw away the
        // part beyond 1 and the average does not fall short of `rate`. After a rest nothing is carried over.
        let gain = min(1, Double(max(rate, 1)) * Double(now - before) / 1_000_000)
        let waiting = move.hasPacket || scroll.hasPacket || !closed.isEmpty
        let streaming = lastOpenSentAt.map { Double(now &- $0) * Double(max(rate, 1)) <= 2_000_000 } ?? false
        credit = min(credit + gain, waiting && streaming ? 2 : 1)
    }

    private func spendCredit(at now: UInt64) {
        lastOpenSentAt = now
        credit = max(0, credit - 1)
    }

    /// The radio did not take the packet; nothing is formed until `radioReady`.
    public func refused() {
        offered = nil
        isBlocked = true
        afterBlock = true
    }

    public func radioReady() {
        isBlocked = false
    }

    // MARK: Barrier

    /// Closes the open movement into packets of their own (with the button state of this moment).
    private func closeMoves() {
        var count = 0
        while move.hasPacket, count < Self.maxSplit {
            let taken = move.take()
            closed.append(payload(
                .move, dx: taken.dx, dy: taken.dy, dt: taken.dt, status: afterBlock ? PointerPayload.statusAfterBlock : 0))
            count += 1
        }
        if move.hasPacket {
            // More than eight full-range packets: the rest is dropped and the last one says so.
            move.x = 0
            move.y = 0
            if var last = closed.last {
                last.status |= PointerPayload.statusTruncated
                closed[closed.count - 1] = last
            }
        }
    }

    private func closeScroll() {
        var count = 0
        while scroll.hasPacket, count < Self.maxSplit {
            let taken = scroll.take()
            closed.append(scrollPayload(scrollBeganSent ? .changed : .began, dx: taken.dx, dy: taken.dy, dt: taken.dt))
            scrollBeganSent = true
            count += 1
        }
        scroll.clear()
    }

    // MARK: Packets

    private func payload(
        _ opcode: PointerPayload.Opcode, dx: Int16 = 0, dy: Int16 = 0, dt: UInt16 = 0, arg: UInt8 = 0, status: UInt8 = 0
    ) -> PointerPayload {
        PointerPayload(opcode: opcode, buttons: buttons, dx: dx, dy: dy, dt: dt, arg: arg, status: status, buttonSeq: buttonSeq)
    }

    private func scrollPayload(_ phase: PointerPayload.ScrollPhase, dx: Int16, dy: Int16, dt: UInt16) -> PointerPayload {
        payload(.scroll, dx: dx, dy: dy, dt: dt, arg: phase.rawValue)
    }
}
