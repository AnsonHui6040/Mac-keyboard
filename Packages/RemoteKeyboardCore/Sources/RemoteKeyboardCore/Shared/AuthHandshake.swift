import CryptoKit
import Foundation

// Challenge-response between an already paired iPhone (peripheral) and a host (central: Mac, Windows or Linux receiver), both
// directions proven with the pair key. Two pure reducers; keys and nonces are injected, nothing here reads a clock or a
// random source. docs/protocol/v4.md §6 is the specification.
//
//   host   → hello(hostId, hostNonce)               written to `control`, only on a connection found through the selected UUID
//   iPhone → helloReply(phoneNonce, phoneProof)     notified on `event`; or notSelected when `hostId` is not its current host
//   host   → auth(hostProof)                        only after the phone proof verified
//   iPhone → sealed(...)                            only after the host proof verified
//
// The iPhone keeps one pair key per host and answers only for its current host. The host holds up to eight phones and does
// not know which one answers: it checks the proof against each stored key in list order and the first match is the phone.
//
// After `auth` verified, both directions are sealed with their own session key (see `SessionCrypto.Direction`): events
// as `PeripheralMessage.sealed`, `ack`, `status` and `bye` as `ControlMessage.sealed`. Before that only `hello`, `auth`,
// `authFailed` and `pairAccept` travel in the clear on `control`, and the app name never does.
//
// Both reducers are single-use: one instance per connection, constructed with a fresh `Pairing.randomNonce()`. Reusing a
// nonce across connections would make a recorded `helloReply` valid again. A new connection needs new reducers.
//
// Once authenticated, each reducer hands out the connection's counter channels exactly once (`takeChannelSet()`); see
// `ChannelSet`. The reducer never exposes a key.
//
// Nothing in the log or in any output carries keys, nonces, proofs or typed text.

public enum HandshakeError: Error, Equatable, Sendable {
    /// `sealEvent` / `sealControl` was called before authentication, or after the handshake failed.
    case notAuthenticated
    /// `sealControl` was given something other than `ack`, `status` or `bye`.
    case invalidControlMessage
}

// MARK: iPhone side

public enum PhoneHandshakeOutput: Equatable, Sendable {
    /// Nothing for the adapter to do (message ignored or dropped).
    case none
    /// Notify this message to the host.
    case send(PeripheralMessage)
    /// The host proved itself; `canSendEvents` is now true.
    case authenticated
    /// A post-authentication host message (`ack`, `status` or `bye`) the app may now act on.
    case deliver(ControlMessage)
    /// The handshake failed. The adapter stops sending events and drops the link.
    case failed
}

public struct PhoneHandshake: Sendable {
    private enum State: Sendable { case awaitingHello, awaitingAuth, authenticated, failed }

    private let selected: (hostId: Data, pairKey: SymmetricKey)?
    private let phoneNonce: Data
    private var state = State.awaitingHello
    private var hostNonce = Data()
    private var eventCrypto: SessionCrypto?
    private var controlCrypto: SessionCrypto?
    private var channelSetTaken = false

    /// - Parameters:
    ///   - selected: the current host's id and the pair key shared with it; `nil` when this iPhone has no current host (nothing
    ///     paired), in which case every well-formed `hello` is answered with `notSelected`.
    ///   - phoneNonce: a fresh `Pairing.randomNonce()` for this connection. Single-use: build a new reducer per connection.
    public init(selected: (hostId: Data, pairKey: SymmetricKey)?, phoneNonce: Data) {
        self.selected = selected
        self.phoneNonce = phoneNonce
    }

    /// True only after the host's `auth` proof verified. Until then the iPhone sends no `KeyboardEvent`.
    public var canSendEvents: Bool { state == .authenticated }

    /// Where the handshake stands, for deciding whether a connected link is worth keeping.
    public enum Progress: Equatable, Sendable {
        /// Waiting for `hello` or for the host's proof.
        case inProgress
        case authenticated
        /// Sticky: this connection will never carry an event.
        case failed
    }

    public var progress: Progress {
        switch state {
        case .awaitingHello, .awaitingAuth: .inProgress
        case .authenticated: .authenticated
        case .failed: .failed
        }
    }

    public mutating func receive(_ message: ControlMessage) -> PhoneHandshakeOutput {
        if state == .failed { return .none }
        switch message {
        case .hello(let hostId, let nonce):
            // docs/protocol/v4.md §6.3, first match wins. 1: a malformed hello fails this connection (the adapter drops
            // such a hello from a central that is not the bound one before it gets here).
            guard hostId.count == IdentityName.idLength, nonce.count == Pairing.nonceLength else { return fail() }
            // 2: meant for another host, or there is no current host. Plain notSelected, no state kept, the same answer
            // whether or not this iPhone was ever paired with `hostId`.
            guard let selected, selected.hostId == hostId else { return .send(.notSelected) }
            // 4: a second hello for this host, before or after auth, is a protocol violation.
            guard state == .awaitingHello else { return fail() }
            guard phoneNonce.count == Pairing.nonceLength else { return fail() }
            hostNonce = nonce
            state = .awaitingAuth
            let proof = Pairing.phoneProof(key: selected.pairKey, hostNonce: nonce, phoneNonce: phoneNonce)
            return .send(.helloReply(phoneNonce: phoneNonce, proof: proof))
        case .auth(let proof):
            guard state == .awaitingAuth, let pairKey = selected?.pairKey,
                  Pairing.verifyHostProof(proof, key: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce) else { return fail() }
            eventCrypto = SessionCrypto(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, direction: .phoneToMac)
            controlCrypto = SessionCrypto(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, direction: .macToPhone)
            state = .authenticated
            return .authenticated
        case .authFailed:
            return fail()
        case .ack, .status, .bye:
            // After auth the host only sends these sealed, so a plain one is a violation. Before auth they are dropped.
            return state == .authenticated ? fail() : .none
        case .sealed(let payload):
            guard state == .authenticated, let controlCrypto, let plain = try? controlCrypto.open(payload),
                  let inner = try? ControlCodec.decode(plain) else { return fail() }
            switch inner {
            case .ack, .status, .bye: return .deliver(inner)
            default: return fail()
            }
        case .pairAccept:
            // Pairing is handled outside the handshake.
            return .none
        }
    }

    /// The counter channels of this connection, once, after the host's proof verified. `nil` before that, after a failure
    /// and on every later call. Keep the result for the life of the connection; asking again would give a second set whose
    /// counters start at 1 under the same keys.
    public mutating func takeChannelSet() -> ChannelSet? {
        guard state == .authenticated, !channelSetTaken, let pairKey = selected?.pairKey else { return nil }
        channelSetTaken = true
        return ChannelSet(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
    }

    /// Wraps one event for the wire: `PeripheralCodec` bytes sealed into `.sealed`. Throws until authenticated.
    public func sealEvent(_ event: KeyboardEvent) throws -> PeripheralMessage {
        guard state == .authenticated, let eventCrypto else { throw HandshakeError.notAuthenticated }
        return .sealed(try eventCrypto.seal(PeripheralCodec.encode(.event(event))))
    }

    private mutating func fail() -> PhoneHandshakeOutput {
        state = .failed
        eventCrypto = nil
        controlCrypto = nil
        return .failed
    }
}

// MARK: Host side

public enum MacHandshakeOutput: Equatable, Sendable {
    /// Ignored (for example any message after a failure was already reported).
    case none
    /// Write this to `control`: the opening `hello`.
    case send(ControlMessage)
    /// The phone proof verified against the key of the phone `phoneId`. Write `reply` (`auth`) to `control`;
    /// `statusToSend` now releases the app name.
    case authenticated(reply: ControlMessage, phoneId: Data)
    /// Pairing step 1 (key commitment). Only the adapter knows whether a pairing window is open; outside it, ignore and disconnect.
    case pairOffer(commitment: Data)
    /// Pairing step 3 (key reveal and phone identity), forwarded for `MacPairing`. Same window rule as `pairOffer`.
    case pairReveal(publicKey: Data, phone: PhoneIdentity)
    /// A verified, decrypted keyboard event.
    case event(KeyboardEvent)
    /// Authenticated and decrypted, but the inner event could not be parsed. Answer `AckCode.malformed`.
    case malformedPayload
    /// The keyboard is typing to another host. Not a failure: disconnect without writing `authFailed`, hold this device off
    /// for `ReceiverLinkStateMachine.handshakeBackoffSeconds` and do not put it on the skip list. Reported once.
    case notSelected
    /// Write `ControlMessage.authFailed`, disconnect, and hold this peripheral off (docs/protocol/v4.md §6.2).
    /// Reported once; later messages produce `.none`.
    case authFailed
}

public struct MacHandshake: Sendable {
    /// How the connection was found (docs/protocol/v4.md §1.5): through the host's selected UUID it only walks the handshake,
    /// through the pairing UUID it only carries pairing.
    public enum Route: Equatable, Sendable { case selected, pairing }

    private enum State: Sendable { case idle, awaitingReply, authenticated, failed }

    private let hostId: Data
    private let phones: [PairedPhone]
    private let hostNonce: Data
    private let route: Route
    private var state: State
    private var sessionKey: SymmetricKey?
    private var eventCrypto: SessionCrypto?
    private var controlCrypto: SessionCrypto?
    private var phoneNonce = Data()
    private var channelSetTaken = false
    /// The failure was already handed to the caller (a host built with a bad nonce reports it from `begin()`).
    private var failureReported = false
    /// The phone whose key matched; set when authenticated.
    public private(set) var authenticatedPhone: PhoneIdentity?

    /// - Parameters:
    ///   - hostId: this host's id (16 bytes), the one `hello` carries.
    ///   - phones: every phone this host is paired with, in storage order (at most eight). Empty when nothing is paired: a
    ///     connection on the `.selected` route then fails from `begin()` before anything is written.
    ///   - hostNonce: a fresh `Pairing.randomNonce()` for this connection. Single-use: build a new reducer per connection.
    ///   - route: `.pairing` for a connection found through the pairing UUID.
    public init(hostId: Data, phones: [PairedPhone], hostNonce: Data, route: Route = .selected) {
        self.hostId = hostId
        self.phones = phones
        self.hostNonce = hostNonce
        self.route = route
        // A malformed own id or nonce fails closed rather than starting a handshake that cannot be checked.
        state = hostNonce.count == Pairing.nonceLength && hostId.count == IdentityName.idLength ? .idle : .failed
    }

    /// True once the phone's proof verified.
    public var isAuthenticated: Bool { state == .authenticated }

    /// Starts the challenge once the keyboard link is ready. On the `.pairing` route nothing is written: the phone speaks
    /// first with `pairOffer`.
    public mutating func begin() -> MacHandshakeOutput {
        guard state == .idle else { return state == .failed && !failureReported ? fail() : .none }
        guard route == .selected else { return .none }
        // No key to check a reply against: a connection through the selected UUID with nobody paired is a failure.
        guard !phones.isEmpty else { return fail() }
        state = .awaitingReply
        return .send(.hello(hostId: hostId, hostNonce: hostNonce))
    }

    /// The app name the receiver may put in a `ReceiverStatus`: `nil` until the phone is verified.
    public func statusToSend(appName: String?) -> String? {
        state == .authenticated ? appName : nil
    }

    /// Before authentication only `helloReply` (selected route) or `pairOffer` and `pairReveal` (pairing route) are
    /// acceptable; afterwards only `sealed`. A plaintext `event` is a protocol violation at every point. `notSelected` is the
    /// one message that ends the connection without a failure.
    public mutating func receive(_ message: PeripheralMessage) -> MacHandshakeOutput {
        if state == .failed { return .none }
        switch message {
        case .event:
            return fail()
        case .pairOffer(let commitment):
            guard route == .pairing, state != .authenticated, commitment.count == Pairing.commitmentLength else { return fail() }
            return .pairOffer(commitment: commitment)
        case .pairReveal(let publicKey, let phone):
            guard route == .pairing, state != .authenticated, publicKey.count == Pairing.publicKeyLength,
                  (try? P256.KeyAgreement.PublicKey(x963Representation: publicKey)) != nil else { return fail() }
            return .pairReveal(publicKey: publicKey, phone: phone)
        case .notSelected:
            guard route == .selected, state != .authenticated else { return fail() }
            state = .failed
            failureReported = true
            return .notSelected
        case .helloReply(let phoneNonce, let proof):
            guard route == .selected, state == .awaitingReply else { return fail() }
            // The host does not know who answers. Every stored key is checked, in constant time each and without stopping at
            // the first hit, so the time taken does not tell where in the list the phone was; the first match is the phone.
            var matched: PairedPhone?
            for entry in phones {
                let ok = Pairing.verifyPhoneProof(proof, key: entry.pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
                if ok && matched == nil { matched = entry }
            }
            guard let phone = matched else { return fail() }
            let pairKey = phone.pairKey
            eventCrypto = SessionCrypto(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, direction: .phoneToMac)
            controlCrypto = SessionCrypto(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, direction: .macToPhone)
            self.phoneNonce = phoneNonce
            sessionKey = pairKey
            authenticatedPhone = phone.identity
            state = .authenticated
            return .authenticated(
                reply: .auth(proof: Pairing.hostProof(key: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)),
                phoneId: phone.identity.id)
        case .sealed(let payload):
            guard state == .authenticated, let eventCrypto, let plain = try? eventCrypto.open(payload) else { return fail() }
            switch try? PeripheralCodec.decode(plain) {
            case .event(let event)?: return .event(event)
            case nil: return .malformedPayload
            default: return fail()
            }
        }
    }

    /// The counter channels of this connection, once, after the phone's proof verified. `nil` before that, after a failure
    /// and on every later call. Keep the result for the life of the connection (see `PhoneHandshake.takeChannelSet()`).
    public mutating func takeChannelSet() -> ChannelSet? {
        guard state == .authenticated, !channelSetTaken, let sessionKey else { return nil }
        channelSetTaken = true
        return ChannelSet(pairKey: sessionKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
    }

    /// Wraps an `ack`, `status` or `bye` for the wire. After authentication the host sends nothing else on `control` except
    /// `authFailed`; anything but those three is refused.
    public func sealControl(_ message: ControlMessage) throws -> ControlMessage {
        guard state == .authenticated, let controlCrypto else { throw HandshakeError.notAuthenticated }
        switch message {
        case .ack, .status, .bye: return .sealed(try controlCrypto.seal(ControlCodec.encode(message)))
        default: throw HandshakeError.invalidControlMessage
        }
    }

    private mutating func fail() -> MacHandshakeOutput {
        state = .failed
        eventCrypto = nil
        controlCrypto = nil
        sessionKey = nil
        authenticatedPhone = nil
        failureReported = true
        return .authFailed
    }
}
