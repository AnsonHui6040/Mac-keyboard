import Foundation

/// Which Bluetooth central the iPhone is talking to.
///
/// A peripheral cannot refuse a connection, so any phone or laptop nearby can subscribe to the service and write to
/// `control`. The first central that subscribes is the one the handshake or the pairing attempt belongs to. Writes from any
/// other central are ignored, and while the bound connection is authenticated a different central can neither take its place
/// nor reset its handshake. Pure decisions only; the adapters hold the radio objects.
public struct CentralBinding: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// This central is now the bound one: start a fresh handshake (or attempt) for it. Also the answer when the bound
        /// central subscribes again: a new subscription is a new connection on the Mac side, so nothing of the old one stays valid.
        case bound
        /// A different central subscribed while the bound one is locked: ignore it.
        case refused
    }

    public private(set) var subscribed: UUID?

    public init() {}

    /// - Parameter locked: the bound connection is authenticated (keyboard) or in a pairing attempt (host App), so it must not
    ///   be replaced or reset.
    public mutating func subscribe(_ central: UUID, locked: Bool) -> Outcome {
        guard let current = subscribed else {
            subscribed = central
            return .bound
        }
        guard current == central || !locked else { return .refused }
        subscribed = central
        return .bound
    }

    /// `true` when the bound central left (the caller tears its state down); `false` for any other central, which changes nothing.
    public mutating func unsubscribe(_ central: UUID) -> Bool {
        guard subscribed == central else { return false }
        subscribed = nil
        return true
    }

    /// A write is fed to the handshake or pairing reducer only when it comes from the bound central.
    public func shouldAcceptWrite(from central: UUID) -> Bool { subscribed == central }

    public mutating func clear() { subscribed = nil }

    /// CoreBluetooth does not reliably report an unsubscribe when the radio goes away, so any state other than powered on
    /// releases the binding.
    public mutating func powerChanged(_ power: PeripheralPower) {
        if power != .poweredOn { subscribed = nil }
    }
}
