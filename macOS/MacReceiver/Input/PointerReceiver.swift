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
    /// The grant of the current connection; `nil` without a connection or with the switch off.
    private(set) var grant: UInt32?
    /// The grant appeared, changed or went away without a new connection (the switch was turned): the status must be sent again.
    var onGrantChange: (() -> Void)?

    private let defaults: UserDefaults
    private let output: PointerOutput
    private let clock: () -> UInt64
    private let makeGrant: () -> UInt32
    private let noteActivity: () -> Void
    private let log: (String) -> Void

    private var channels: ChannelSet?
    private var engine = PointerEngine()
    private var watchdog: Timer?
    private var consecutiveFailures = 0
    private var lastActivityAt: UInt64?
    private var packets = 0
    private var rejected = 0

    /// - Parameters:
    ///   - clock: monotonic microseconds.
    ///   - makeGrant: a new grant value each call.
    ///   - noteActivity: extends the receiving session (D13); called at most once a second.
    init(
        defaults: UserDefaults = .standard, output: PointerOutput, clock: @escaping () -> UInt64 = { PointerClock.nowMicros() },
        makeGrant: @escaping () -> UInt32 = { UInt32.random(in: 1...UInt32.max) },
        noteActivity: @escaping () -> Void = {}, log: @escaping (String) -> Void = { PointerReceiver.osLog.info("\($0, privacy: .public)") }
    ) {
        self.defaults = defaults
        self.output = output
        self.clock = clock
        self.makeGrant = makeGrant
        self.noteActivity = noteActivity
        self.log = log
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
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
        apply(engine.reset())
        engine = PointerEngine()
        isOpen = true
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
        let actions = engine.reset()
        apply(actions)
        stopWatchdog()
        guard isOpen else { return }
        isOpen = false
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
            apply(engine.handle(payload, nowMicros: now))
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
        apply(engine.watchdog(nowMicros: clock()))
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

    private func apply(_ actions: [PointerAction]) {
        guard !actions.isEmpty else { return }
        output.apply(actions)
    }
}
