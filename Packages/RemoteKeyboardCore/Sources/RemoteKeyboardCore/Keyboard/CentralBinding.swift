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

    /// What to do with a `hello` written to `control` (docs/protocol/v4.md §6.3).
    public enum HelloDisposition: Equatable, Sendable {
        /// Feed it to the handshake reducer of the bound central.
        case handshake
        /// Notify one plain `notSelected` to the central that wrote it, keep no state.
        case replyNotSelected
        /// Do nothing.
        case ignore
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

    /// Decides what a `hello` from `central` means. A `hello` is the one write that a central other than the bound one may
    /// make, so this is where it is kept away from the bound connection.
    ///
    /// - A host that is not the current host (`hostIdMatches` is false): `.replyNotSelected`. When the writer is the bound
    ///   central the binding is released at the same time (that central has to try again for the right host); a different
    ///   central changes nothing, in particular not an authenticated connection.
    /// - The current host, from the bound central: `.handshake`.
    /// - The current host, from another central: `.ignore` while the bound connection is `locked` (authenticated); otherwise
    ///   the binding moves to it and the answer is `.handshake`, so the adapter starts a fresh handshake for the new central.
    public mutating func helloDisposition(from central: UUID, hostIdMatches: Bool, locked: Bool) -> HelloDisposition {
        guard hostIdMatches else {
            if subscribed == central { subscribed = nil }
            return .replyNotSelected
        }
        if subscribed == central { return .handshake }
        guard !locked else { return .ignore }
        subscribed = central
        return .handshake
    }

    /// The same decision from the message itself. A `hello` whose `hostId` or `hostNonce` is not 16 bytes is malformed: from
    /// the bound central it goes to the handshake reducer (which fails the connection), from any other central it is ignored,
    /// and in neither case is it answered with `notSelected`. `currentHostId` is the id of the host the keyboard types to,
    /// `nil` when it has none. Anything that is not a `hello` is `.ignore`.
    public mutating func helloDisposition(
        from central: UUID, hello: ControlMessage, currentHostId: Data?, locked: Bool
    ) -> HelloDisposition {
        guard case .hello(let hostId, let hostNonce) = hello else { return .ignore }
        guard hostId.count == IdentityName.idLength, hostNonce.count == Pairing.nonceLength else {
            return subscribed == central ? .handshake : .ignore
        }
        return helloDisposition(from: central, hostIdMatches: hostId == currentHostId, locked: locked)
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
