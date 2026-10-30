public enum LinkFailure: Equatable, Sendable {
    case addService, advertise
}

public enum KeyboardLinkState: Equatable, Sendable {
    case idle, noFullAccess, unavailable(PeripheralPower), publishing, advertising, connected, failed(LinkFailure)

    /// Stable state name, also used as the status label accessibility value.
    public var name: String {
        switch self {
        case .idle: "idle"
        case .noFullAccess: "no-full-access"
        case .unavailable: "unavailable"
        case .publishing: "publishing"
        case .advertising: "advertising"
        case .connected: "connected"
        case .failed: "failed"
        }
    }

    public var statusText: String {
        switch self {
        case .failed(.addService): "BLE: failed (addService)"
        case .failed(.advertise): "BLE: failed (advertise)"
        default: "BLE: \(name)"
        }
    }
}

public enum KeyboardLinkInput: Equatable {
    case appeared(hasFullAccess: Bool), disappeared, power(PeripheralPower)
    case serviceAdded(ok: Bool), advertisingStarted(ok: Bool), subscribed, unsubscribed
    /// The connection is dead or was ended on purpose (the Mac said goodbye, or a liveness probe went unanswered), and
    /// iOS may not report an unsubscribe. Publish the service again from scratch so every old subscription is dropped.
    case linkReset
}

public enum KeyboardLinkEffect: Equatable {
    case addService, startAdvertising, stopAdvertising, removeServices
}

/// Publishes and advertises only while the keyboard is visible, Full Access is on and Bluetooth is powered on.
public struct KeyboardLinkStateMachine {
    public private(set) var state: KeyboardLinkState = .idle
    private var power: PeripheralPower = .unknown
    private var visible = false
    private var hasFullAccess = false

    public init() {}

    public mutating func handle(_ input: KeyboardLinkInput) -> [KeyboardLinkEffect] {
        switch input {
        case .appeared(let fullAccess):
            if visible && hasFullAccess == fullAccess { return [] }
            let cleanup = teardownEffects()
            visible = true
            hasFullAccess = fullAccess
            guard fullAccess else {
                state = .noFullAccess
                return cleanup
            }
            return cleanup + evaluate()
        case .disappeared:
            let effects = teardownEffects()
            visible = false
            hasFullAccess = false
            state = .idle
            return effects
        case .power(let newPower):
            power = newPower
            guard visible, hasFullAccess else { return [] }
            if newPower == .poweredOn {
                switch state {
                case .unavailable: return evaluate()
                default: return []
                }
            }
            state = .unavailable(newPower)
            return []
        case .serviceAdded(let ok):
            guard state == .publishing else { return [] }
            if ok { return [.startAdvertising] }
            state = .failed(.addService)
            return []
        case .advertisingStarted(let ok):
            switch state {
            case .publishing, .advertising:
                state = ok ? .advertising : .failed(.advertise)
            default:
                break
            }
            return []
        case .subscribed:
            guard state == .advertising else { return [] }
            state = .connected
            return [.stopAdvertising]
        case .unsubscribed:
            guard state == .connected else { return [] }
            state = .advertising
            return [.startAdvertising]
        case .linkReset:
            guard visible, hasFullAccess else { return [] }
            switch state {
            case .publishing, .advertising, .connected, .failed:
                // Advertising again is not enough: iOS may still count the old central as subscribed. Removing the
                // service and adding it anew is what drops every subscription, as a controller change does.
                return teardownEffects() + evaluate()
            case .idle, .noFullAccess, .unavailable:
                return []
            }
        }
    }

    private mutating func evaluate() -> [KeyboardLinkEffect] {
        if power == .poweredOn {
            state = .publishing
            return [.addService]
        }
        state = .unavailable(power)
        return []
    }

    private func teardownEffects() -> [KeyboardLinkEffect] {
        switch state {
        case .publishing, .advertising, .connected: [.stopAdvertising, .removeServices]
        case .failed(.advertise): [.removeServices]
        default: []
        }
    }
}
