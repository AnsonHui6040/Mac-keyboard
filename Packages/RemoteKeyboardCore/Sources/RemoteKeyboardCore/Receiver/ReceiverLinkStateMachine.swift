import Foundation

public enum CentralPower: Sendable {
    case unknown, poweredOff, unauthorized, unsupported, poweredOn
}

public enum ReceiverLinkState: Equatable, Sendable {
    case idle, unavailable(CentralPower), scanning, connecting(UUID), discovering(UUID), ready(UUID)

    /// Stable state name for the menu and logs.
    public var name: String {
        switch self {
        case .idle: "idle"
        case .unavailable: "unavailable"
        case .scanning: "scanning"
        case .connecting: "connecting"
        case .discovering: "discovering"
        case .ready: "ready"
        }
    }
}

extension ReceiverLinkState {
    /// Why the Mac cannot receive, for the menu bar panel. `nil` while the radio is usable.
    public var reasonText: String? {
        guard case .unavailable(let power) = self else { return nil }
        switch power {
        case .poweredOff: return "藍牙已關閉，請在 Mac 開啟藍牙"
        case .unauthorized: return "未授權藍牙，請到系統設定 › 隱私權與安全性 允許"
        case .unsupported: return "這台 Mac 不支援藍牙"
        // Unknown is the moment before CoreBluetooth reports; showing a reason then would only flash.
        case .unknown, .poweredOn: return nil
        }
    }
}

public enum ReceiverLinkInput: Equatable {
    case start, stop, power(CentralPower)
    case discovered(UUID), connected(UUID), linkReady(UUID), disconnected(UUID), serviceInvalidated(UUID)
    case connectTimeout
    /// The backoff delay requested by `startScanAfter` has elapsed.
    case rescanTimer
    /// The handshake of the ready connection did not finish in time. Disconnects it and holds that device off for
    /// `handshakeBackoffSeconds`; the search for other devices goes on.
    case handshakeTimeout(UUID)
    /// The keyboard answered `hello` with `notSelected`: it types to another host. Same treatment as a handshake timeout.
    case notSelected(UUID)
    /// The keyboard speaks another protocol version. Disconnects it and holds that device off for
    /// `unsupportedVersionHoldSeconds`; the search for other devices goes on.
    case unsupportedVersion(UUID)
}

public enum ReceiverLinkEffect: Equatable {
    case startScan, stopScan, connect(UUID), discover(UUID), cancel(UUID)
    case startConnectTimeout(seconds: Double), cancelConnectTimeout
    /// Rescan after a delay (answered by `rescanTimer`) instead of at once, so repeated handshake failures cannot hot-loop.
    case startScanAfter(seconds: Double), cancelRescanTimer
}

/// Keeps looking for the keyboard while started. Only `stop` or an unusable radio ends the search.
///
/// A device that must not be reconnected right away (it answered `notSelected`, its handshake timed out, or it speaks
/// another protocol version) goes on one list of held devices with an expiry. Only that device is skipped when it is
/// discovered again; the scan is neither delayed nor stopped for anyone else. The list needs a clock, which is injected.
public struct ReceiverLinkStateMachine {
    public static let connectTimeoutSeconds = 5.0
    /// How long a device is left alone after `notSelected` or a handshake timeout (Provisional, docs/protocol/v4.md §6.4).
    public static let handshakeBackoffSeconds = 10.0
    /// How long a device is left alone after a protocol version mismatch (Provisional, docs/protocol/v4.md §10).
    public static let unsupportedVersionHoldSeconds = 60.0

    public private(set) var state: ReceiverLinkState = .idle
    private var power: CentralPower = .unknown
    private var started = false
    /// Consecutive failed handshakes; a ready link, stop or an unusable radio start the count over.
    private var handshakeFailures = 0
    private var rescanPending = false
    /// True while the scan waits out a backoff after failed handshakes; a scan started now would skip it.
    public var isBackingOff: Bool { rescanPending }
    /// Held devices and the time (on the injected clock) until which each is left alone.
    private var holds: [UUID: Double] = [:]
    /// How many devices are held now, expired ones not yet swept included.
    var heldDeviceCount: Int { holds.count }
    private let now: () -> Double

    /// - Parameter now: seconds on a monotonic clock. The default is the system uptime; tests pass their own.
    public init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// The first failure rescans at once (it already cost the connect timeout); later ones wait 0.5, 1, then 2 seconds.
    public static func backoffSeconds(afterFailures failures: Int) -> Double {
        failures <= 1 ? 0 : min(0.5 * Double(1 << min(failures - 2, 8)), 2)
    }

    public mutating func handle(_ input: ReceiverLinkInput) -> [ReceiverLinkEffect] {
        switch input {
        case .start:
            guard !started else { return [] }
            started = true
            return evaluate()
        case .stop:
            started = false
            return teardown(to: .idle)
        case .power(let new):
            power = new
            guard started else { return [] }
            return evaluate()
        case .discovered(let id):
            guard state == .scanning, !rescanPending, !isHeld(id) else { return [] }
            state = .connecting(id)
            return [.stopScan, .connect(id), .startConnectTimeout(seconds: Self.connectTimeoutSeconds)]
        case .connected(let id):
            guard state == .connecting(id) else { return [] }
            state = .discovering(id)
            return [.discover(id)]
        case .linkReady(let id):
            guard state == .discovering(id) else { return [] }
            state = .ready(id)
            handshakeFailures = 0
            return [.cancelConnectTimeout]
        case .disconnected(let id):
            guard current == id else { return [] }
            let failed = isHandshaking
            let cleanup: [ReceiverLinkEffect] = failed ? [.cancelConnectTimeout] : []
            state = .scanning
            return cleanup + scanEffects(afterFailure: failed)
        case .serviceInvalidated(let id):
            guard current == id else { return [] }
            return rescan(cancelling: id, timeoutPending: isHandshaking, failed: isHandshaking)
        case .connectTimeout:
            guard isHandshaking, let id = current else { return [] }
            return rescan(cancelling: id, timeoutPending: false, failed: true)
        case .rescanTimer:
            guard rescanPending, state == .scanning else { return [] }
            rescanPending = false
            return [.startScan]
        case .handshakeTimeout(let id), .notSelected(let id):
            return hold(id, seconds: Self.handshakeBackoffSeconds)
        case .unsupportedVersion(let id):
            return hold(id, seconds: Self.unsupportedVersionHoldSeconds)
        }
    }

    /// Disconnects the ready connection `id` and leaves that device alone for `seconds`. The state stays `.ready(id)` until the
    /// adapter reports the disconnect, which then restarts the scan at once (it is not a failed handshake attempt). A longer
    /// hold already in place is kept.
    private mutating func hold(_ id: UUID, seconds: Double) -> [ReceiverLinkEffect] {
        guard state == .ready(id) else { return [] }
        let current = now()
        holds = holds.filter { $0.value > current }
        holds[id] = max(holds[id] ?? 0, current + seconds)
        return [.cancel(id)]
    }

    private mutating func isHeld(_ id: UUID) -> Bool {
        guard let until = holds[id] else { return false }
        if now() < until { return true }
        holds[id] = nil
        return false
    }

    private var current: UUID? {
        switch state {
        case .connecting(let id), .discovering(let id), .ready(let id): id
        default: nil
        }
    }

    private var isHandshaking: Bool {
        switch state {
        case .connecting, .discovering: true
        default: false
        }
    }

    private mutating func rescan(cancelling id: UUID, timeoutPending: Bool, failed: Bool) -> [ReceiverLinkEffect] {
        state = .scanning
        return (timeoutPending ? [.cancelConnectTimeout] : []) + [.cancel(id)] + scanEffects(afterFailure: failed)
    }

    /// Starts scanning at once, or after the backoff when handshakes keep failing.
    private mutating func scanEffects(afterFailure failed: Bool) -> [ReceiverLinkEffect] {
        guard failed else { return [.startScan] }
        handshakeFailures += 1
        let delay = Self.backoffSeconds(afterFailures: handshakeFailures)
        guard delay > 0 else { return [.startScan] }
        rescanPending = true
        return [.startScanAfter(seconds: delay)]
    }

    private mutating func evaluate() -> [ReceiverLinkEffect] {
        if power == .poweredOn {
            switch state {
            case .idle, .unavailable:
                state = .scanning
                return [.startScan]
            default:
                return []
            }
        }
        return teardown(to: .unavailable(power))
    }

    /// Releases whatever the current state holds and moves to `target`.
    private mutating func teardown(to target: ReceiverLinkState) -> [ReceiverLinkEffect] {
        let effects: [ReceiverLinkEffect]
        switch state {
        case .scanning: effects = rescanPending ? [.cancelRescanTimer] : [.stopScan]
        case .connecting(let id), .discovering(let id): effects = [.cancelConnectTimeout, .cancel(id)]
        case .ready(let id): effects = [.cancel(id)]
        case .idle, .unavailable: effects = []
        }
        state = target
        rescanPending = false
        handshakeFailures = 0
        if target == .idle { holds = [:] }
        return effects
    }
}
