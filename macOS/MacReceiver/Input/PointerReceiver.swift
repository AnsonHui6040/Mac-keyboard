import Foundation
import OSLog
import RemoteKeyboardCore

/// Where the actions of a pointer packet end up. The product posts CGEvents; tests record.
@MainActor
protocol PointerOutput: AnyObject {
    func apply(_ actions: [PointerAction])
}

/// The Mac side of the touchpad: who may use it, and what an accepted `0x03` packet does.
///
/// - **Switch** 「允許觸控板控制」 (stored, on by default in this version). With it on, each authenticated connection gets its own
///   `grant` (and every turning on a new one), which the status tells the keyboard. Turning it off closes the channel and
///   takes the grant away.
/// - **Open** (`pointerOpen`): needs an authenticated connection, the switch on and the current grant; then packets are
///   accepted. Every packet checks the same again. `pointerClose`, a lost connection, the switch going off, eight failed packets
///   in a row and quitting all close the channel and let go of whatever is held.
/// - **Packets** are opened with the connection's `ChannelSet` (`.pointer` opener: counter nonce, AAD, 64-bit replay window),
///   read by `PointerPayload.decode`, and turned into actions by `PointerEngine`. A packet that does not verify is dropped and
///   counted.
/// - **Cursor movement is played out, not posted on arrival.** The radio delivers packets in bunches, so a MOVE is handed to
///   `PointerPlayout`, which spreads it over the time the finger took, and one share is posted per screen refresh
///   (`PointerFrameSource`, running only while something is waiting). Anything else (a click, a button, a scroll, the watchdog
///   letting go) first flushes the movement before it, so the order the phone sent is the order the Mac performs. When the channel
///   closes the movement not yet played is dropped, not performed.
/// - **Link statistics**: arrival times and `dt` of the movement and scroll packets are kept for 5 seconds (times and counts
///   only) and shown as one line; closing the channel logs one aggregate line and clears them.
/// - The watchdog timer runs only while a button is held or a scroll is going.
///
/// The log holds event names and counts only: never a position, a displacement or anything typed.
@MainActor
final class PointerReceiver: ObservableObject {
    static let enabledKey = "rk.pointerEnabled"
    static let maxConsecutiveFailures = 8
    static let activityIntervalMicros: UInt64 = 1_000_000
    static let watchdogInterval: TimeInterval = 0.05
    static let osLog = Logger(subsystem: "com.ansonhui.remotekeyboard.receiver", category: "pointer")

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isOpen = false
    /// A few short lines about the link for the panel (see `PointerLinkStats`), refreshed once a second while the channel is open; `nil`
    /// when closed or with too few packets.
    @Published private(set) var linkSummary: [String]?
    /// Where uneven cursor motion comes from (`PointerPlayoutDiagnostics`), a few short lines; same lifetime as `linkSummary`.
    @Published private(set) var playoutSummary: [String]?
    /// The grant of the current connection; `nil` without a connection or with the switch off.
    private(set) var grant: UInt32?
    /// The grant appeared, changed or went away without a new connection (the switch was turned): the status must be sent again.
    var onGrantChange: (() -> Void)?

    private let defaults: UserDefaults
    private let output: PointerOutput
    private let frames: PointerFrameSource
    private let clock: () -> UInt64
    private let makeGrant: () -> UInt32
    private let noteActivity: () -> Void
    private let log: (String) -> Void

    private var channels: ChannelSet?
    private var engine = PointerEngine()
    private var playout = PointerPlayout()
    private var watchdog: Timer?
    private var statsTimer: Timer?
    private var stats = PointerLinkStats()
    private var diagnostics = PointerPlayoutDiagnostics()
    private var consecutiveFailures = 0
    private var lastActivityAt: UInt64?
    private var packets = 0
    private var rejected = 0

    /// - Parameters:
    ///   - clock: monotonic microseconds.
    ///   - makeGrant: a new grant value each call.
    ///   - noteActivity: extends the receiving session (D13); called at most once a second.
    init(
        defaults: UserDefaults = .standard, output: PointerOutput, frames: PointerFrameSource = DisplayLinkFrameSource(),
        clock: @escaping () -> UInt64 = { PointerClock.nowMicros() },
        makeGrant: @escaping () -> UInt32 = { UInt32.random(in: 1...UInt32.max) },
        noteActivity: @escaping () -> Void = {}, log: @escaping (String) -> Void = { PointerReceiver.osLog.info("\($0, privacy: .public)") }
    ) {
        self.defaults = defaults
        self.output = output
        self.frames = frames
        self.clock = clock
        self.makeGrant = makeGrant
        self.noteActivity = noteActivity
        self.log = log
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        frames.onFrame = { [weak self] timestamp, target in self?.frameTick(timestampMicros: timestamp, targetMicros: target) }
    }

    // MARK: Switch

    func setEnabled(_ on: Bool) {
        guard on != isEnabled else { return }
        isEnabled = on
        defaults.set(on, forKey: Self.enabledKey)
        let hadGrant = grant != nil
        if on {
            guard channels != nil else { return }
            grant = makeGrant()
            onGrantChange?()
        } else {
            closeChannel(reason: "switch-off")
            grant = nil
            if hadGrant { onGrantChange?() }
        }
    }

    // MARK: Connection

    /// A new authenticated connection. It brings its own counters, so nothing of an earlier one is kept. The first status is
    /// sent by the caller right after this, so the new grant is not announced separately.
    func attach(_ channels: ChannelSet) {
        closeChannel(reason: "new-connection")
        self.channels = channels
        grant = isEnabled ? makeGrant() : nil
    }

    func detach() {
        closeChannel(reason: "link-lost")
        channels = nil
        grant = nil
    }

    /// The Receiver is quitting.
    func shutdown() {
        closeChannel(reason: "quit")
    }

    // MARK: Open and close

    /// Answers a `pointerOpen`. The permission is checked again here, not taken from an earlier answer.
    func handleOpen(grant requested: UInt32) -> AckCode {
        guard channels != nil, isEnabled, let current = grant, current == requested else {
            log("pointer open refused")
            return .notAuthorized
        }
        dropPlayout()
        apply(engine.reset())
        engine = PointerEngine()
        isOpen = true
        stats.reset()
        diagnostics.reset()
        startStatsTimer()
        consecutiveFailures = 0
        packets = 0
        rejected = 0
        log("pointer open")
        return .posted
    }

    func handleClose() -> AckCode {
        closeChannel(reason: "close")
        return .posted
    }

    private func closeChannel(reason: String) {
        dropPlayout()
        let actions = engine.reset()
        apply(actions)
        stopWatchdog()
        guard isOpen else { return }
        isOpen = false
        logLinkSummary()
        stopStatsTimer()
        log("pointer closed reason=\(reason) packets=\(packets) rejected=\(rejected)")
    }

    // MARK: Packets

    /// One `0x03` notification, whole.
    func handle(_ packet: Data) {
        // Every packet checks again: channel open, connection authenticated, switch still on.
        guard isOpen, isEnabled, grant != nil, let channels else { return }
        switch channels.opener(.pointer).open(packet) {
        case .failure(let error):
            rejected += 1
            consecutiveFailures += 1
            log("pointer packet rejected reason=\(String(describing: error))")
            if consecutiveFailures >= Self.maxConsecutiveFailures { closeChannel(reason: "failures") }
        case .success(let plain):
            consecutiveFailures = 0
            guard let payload = PointerPayload.decode(plain) else {
                rejected += 1
                log("pointer payload unreadable")
                return
            }
            packets += 1
            let now = clock()
            if payload.opcode == .move || payload.opcode == .scroll { stats.record(arrivalMicros: now, dtTenths: payload.dt) }
            if payload.opcode == .move, payload.dx != 0 || payload.dy != 0 {
                diagnostics.recordMove(arrivalMicros: now, dxSixteenths: payload.dx, dySixteenths: payload.dy, dtTenths: payload.dt)
            }
            route(engine.handle(payload, nowMicros: now), spanMicros: UInt64(payload.dt) * 100, nowMicros: now)
            noteActivityIfDue(now)
            updateWatchdog()
        }
    }

    private func noteActivityIfDue(_ now: UInt64) {
        if let last = lastActivityAt, now &- last < Self.activityIntervalMicros { return }
        lastActivityAt = now
        noteActivity()
    }

    // MARK: Watchdog

    /// Called by the timer while a button is held or a scroll is going; internal so a test can drive it.
    func watchdogTick() {
        let now = clock()
        route(engine.watchdog(nowMicros: now), spanMicros: 0, nowMicros: now)
        updateWatchdog()
    }

    private func updateWatchdog() {
        if engine.needsWatchdog {
            guard watchdog == nil else { return }
            watchdog = CommonModeTimer.make(Self.watchdogInterval, repeats: true) { [weak self] in self?.watchdogTick() }
        } else {
            stopWatchdog()
        }
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    // MARK: Link statistics

    private func startStatsTimer() {
        stopStatsTimer()
        statsTimer = CommonModeTimer.make(1, repeats: true) { [weak self] in self?.refreshLinkSummary() }
    }

    private func stopStatsTimer() {
        statsTimer?.invalidate()
        statsTimer = nil
        stats.reset()
        diagnostics.reset()
        linkSummary = nil
        playoutSummary = nil
    }

    /// Called once a second by the timer; internal so a test can drive it.
    func refreshLinkSummary() {
        let lines = stats.snapshot(nowMicros: clock())?.lines
        if lines != linkSummary { linkSummary = lines }
        let diag = diagnostics.snapshot(nowMicros: clock())?.lines
        if diag != playoutSummary { playoutSummary = diag }
    }

    /// Counts and milliseconds only.
    private func logLinkSummary() {
        let now = clock()
        if let d = diagnostics.snapshot(nowMicros: now) {
            log("pointer diag stalled=\(Int(d.stalledFramePercent.rounded()))% longest=\(d.longestStall) squeezes=\(d.squeezeCount) cb50=\(Int(d.callbackIntervalP50Millis.rounded()))ms cb95=\(Int(d.callbackIntervalP95Millis.rounded()))ms margin10=\(Int(d.marginP10Millis.rounded()))ms margin50=\(Int(d.marginP50Millis.rounded()))ms gain50=\(String(format: "%.2f", d.gainJumpP50)) gain90=\(String(format: "%.2f", d.gainJumpP90))")
        }
        guard let s = stats.snapshot(nowMicros: now) else { return }
        log("pointer link rate=\(Int(s.packetsPerSecond.rounded())) p50=\(Int(s.arrivalP50Millis.rounded()))ms p95=\(Int(s.arrivalP95Millis.rounded()))ms interval=\(Int(s.estimatedConnectionIntervalMillis.rounded()))ms backlog=\(Int(s.backlogGrowthMillis.rounded()))ms")
    }

    // MARK: Playout

    /// Moves go to the playout; every other action first lets out the moves queued before it, then runs.
    private func route(_ actions: [PointerAction], spanMicros: UInt64, nowMicros now: UInt64) {
        for action in actions {
            if case .move(let dx, let dy, let dragging) = action {
                let squeezesBefore = playout.squeezeCount
                playout.enqueue(dx: dx, dy: dy, dragging: dragging, spanMicros: spanMicros, nowMicros: now)
                if playout.squeezeCount != squeezesBefore { diagnostics.recordSqueeze(atMicros: now) }
            } else {
                flushPlayout()
                apply([action])
            }
        }
        if !playout.isIdle {
            frames.start()
        } else if frames.isRunning {
            frames.stop()
        }
    }

    private func flushPlayout() {
        guard !playout.isIdle else { return }
        apply(playout.flush().map { .move(dx: $0.dx, dy: $0.dy, dragging: $0.dragging) })
    }

    /// One screen refresh: posts what has become due, and stops the frame source once the queue is empty.
    func frameTick(timestampMicros: UInt64, targetMicros: UInt64) {
        let now = clock()
        var due: [PointerAction] = []
        while let share = playout.take(nowMicros: now) {
            due.append(.move(dx: share.dx, dy: share.dy, dragging: share.dragging))
        }
        apply(due)
        diagnostics.recordFrame(nowMicros: now, timestampMicros: timestampMicros, targetMicros: targetMicros, delivered: !due.isEmpty)
        if playout.isIdle, frames.isRunning { frames.stop() }
    }

    /// The channel is over: whatever was not played is not performed any more.
    private func dropPlayout() {
        playout.discard()
        if frames.isRunning { frames.stop() }
    }

    private func apply(_ actions: [PointerAction]) {
        guard !actions.isEmpty else { return }
        output.apply(actions)
    }
}
