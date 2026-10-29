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

public enum ReceiverLinkInput: Equatable {
    case start, stop, power(CentralPower)
    case discovered(UUID), connected(UUID), linkReady(UUID), disconnected(UUID), serviceInvalidated(UUID)
    case connectTimeout
}

public enum ReceiverLinkEffect: Equatable {
    case startScan, stopScan, connect(UUID), discover(UUID), cancel(UUID)
    case startConnectTimeout(seconds: Double), cancelConnectTimeout
}

/// Keeps looking for the keyboard while started. Only `stop` or an unusable radio ends the search.
public struct ReceiverLinkStateMachine {
    public static let connectTimeoutSeconds = 5.0

    public private(set) var state: ReceiverLinkState = .idle
    private var power: CentralPower = .unknown
    private var started = false

    public init() {}

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
            guard state == .scanning else { return [] }
            state = .connecting(id)
            return [.stopScan, .connect(id), .startConnectTimeout(seconds: Self.connectTimeoutSeconds)]
        case .connected(let id):
            guard state == .connecting(id) else { return [] }
            state = .discovering(id)
            return [.discover(id)]
        case .linkReady(let id):
            guard state == .discovering(id) else { return [] }
            state = .ready(id)
            return [.cancelConnectTimeout]
        case .disconnected(let id):
            guard current == id else { return [] }
            let cleanup: [ReceiverLinkEffect] = isHandshaking ? [.cancelConnectTimeout] : []
            state = .scanning
            return cleanup + [.startScan]
        case .serviceInvalidated(let id):
            guard current == id else { return [] }
            return rescan(cancelling: id, timeoutPending: isHandshaking)
        case .connectTimeout:
            guard isHandshaking, let id = current else { return [] }
            return rescan(cancelling: id, timeoutPending: false)
        }
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

    private mutating func rescan(cancelling id: UUID, timeoutPending: Bool) -> [ReceiverLinkEffect] {
        state = .scanning
        return (timeoutPending ? [.cancelConnectTimeout] : []) + [.cancel(id), .startScan]
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
        case .scanning: effects = [.stopScan]
        case .connecting(let id), .discovering(let id): effects = [.cancelConnectTimeout, .cancel(id)]
        case .ready(let id): effects = [.cancel(id)]
        case .idle, .unavailable: effects = []
        }
        state = target
        return effects
    }
}
