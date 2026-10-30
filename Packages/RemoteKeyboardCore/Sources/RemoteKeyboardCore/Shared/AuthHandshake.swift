import CryptoKit
import Foundation

// Challenge-response between an already paired iPhone (peripheral) and Mac (central), both directions proven with the
// pair key. Two pure reducers; keys and nonces are injected, nothing here reads a clock or a random source.
//
//   Mac    → hello(macNonce)                      written to `control`
//   iPhone → helloReply(phoneNonce, phoneProof)   notified on `event`
//   Mac    → auth(macProof)                       only after the phone proof verified
//   iPhone → sealed(...)                          only after the Mac proof verified
//
// After `auth` verified, both directions are sealed with their own session key (see `SessionCrypto.Direction`): events
// as `PeripheralMessage.sealed`, `ack` and `status` as `ControlMessage.sealed`. Before that only `hello`, `auth`,
// `authFailed` and `pairAccept` travel in the clear on `control`, and the app name never does.
//
// Both reducers are single-use: one instance per connection, constructed with a fresh `Pairing.randomNonce()`. Reusing a
// nonce across connections would make a recorded `helloReply` valid again. A new connection needs new reducers.
//
// Nothing in the log or in any output carries keys, nonces, proofs or typed text.

public enum HandshakeError: Error, Equatable, Sendable {
    /// `sealEvent` / `sealControl` was called before authentication, or after the handshake failed.
    case notAuthenticated
    /// `sealControl` was given something other than `ack` or `status`.
    case invalidControlMessage
}

// MARK: iPhone side

public enum PhoneHandshakeOutput: Equatable, Sendable {
    /// Nothing for the adapter to do (message ignored or dropped).
    case none
    /// Notify this message to the Mac.
    case send(PeripheralMessage)
    /// The Mac proved itself; `canSendEvents` is now true.
    case authenticated
    /// A post-authentication Mac message (`ack` or `status`) the app may now act on.
    case deliver(ControlMessage)
    /// The handshake failed. The adapter stops sending events and drops the link.
    case failed
}

public struct PhoneHandshake: Sendable {
    private enum State: Sendable { case awaitingHello, awaitingAuth, authenticated, failed }

    private let pairKey: SymmetricKey?
    private let phoneNonce: Data
    private var state = State.awaitingHello
    private var macNonce = Data()
    private var eventCrypto: SessionCrypto?
    private var controlCrypto: SessionCrypto?

    /// - Parameters:
    ///   - pairKey: `nil` when this iPhone holds no pairing; the handshake then fails on the first `hello`.
    ///   - phoneNonce: a fresh `Pairing.randomNonce()` for this connection. Single-use: build a new reducer per connection.
    public init(pairKey: SymmetricKey?, phoneNonce: Data) {
        self.pairKey = pairKey
        self.phoneNonce = phoneNonce
    }

    /// True only after the Mac's `auth` proof verified. Until then the iPhone sends no `KeyboardEvent`.
    public var canSendEvents: Bool { state == .authenticated }

    public mutating func receive(_ message: ControlMessage) -> PhoneHandshakeOutput {
        if state == .failed { return .none }
        switch message {
        case .hello(let nonce):
            // A second hello, before or after auth, is a protocol violation.
            guard state == .awaitingHello else { return fail() }
            guard let pairKey, nonce.count == Pairing.nonceLength, phoneNonce.count == Pairing.nonceLength else { return fail() }
            macNonce = nonce
            state = .awaitingAuth
            let proof = Pairing.phoneProof(key: pairKey, macNonce: nonce, phoneNonce: phoneNonce)
            return .send(.helloReply(phoneNonce: phoneNonce, proof: proof))
        case .auth(let proof):
            guard state == .awaitingAuth, let pairKey,
                  Pairing.verifyMacProof(proof, key: pairKey, macNonce: macNonce, phoneNonce: phoneNonce) else { return fail() }
            eventCrypto = SessionCrypto(pairKey: pairKey, macNonce: macNonce, phoneNonce: phoneNonce, direction: .phoneToMac)
            controlCrypto = SessionCrypto(pairKey: pairKey, macNonce: macNonce, phoneNonce: phoneNonce, direction: .macToPhone)
            state = .authenticated
            return .authenticated
        case .authFailed:
            return fail()
        case .ack, .status:
            // After auth the Mac only sends these sealed, so a plain one is a violation. Before auth they are dropped.
            return state == .authenticated ? fail() : .none
        case .sealed(let payload):
            guard state == .authenticated, let controlCrypto, let plain = try? controlCrypto.open(payload),
                  let inner = try? ControlCodec.decode(plain) else { return fail() }
            switch inner {
            case .ack, .status: return .deliver(inner)
            default: return fail()
            }
        case .pairAccept:
            // Pairing is handled outside the handshake.
            return .none
        }
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

// MARK: Mac side

public enum MacHandshakeOutput: Equatable, Sendable {
    /// Ignored (for example any message after a failure was already reported).
    case none
    /// Write this to `control`: the opening `hello`.
    case send(ControlMessage)
    /// The phone proof verified. Write `reply` (`auth`) to `control`; `statusToSend` now releases the app name.
    case authenticated(reply: ControlMessage)
    /// Pairing step 1 (key commitment). Only the adapter knows whether a pairing window is open; outside it, ignore and disconnect.
    case pairOffer(commitment: Data)
    /// Pairing step 3 (key reveal), forwarded for `MacPairing`. Same window rule as `pairOffer`.
    case pairReveal(publicKey: Data)
    /// A verified, decrypted keyboard event.
    case event(KeyboardEvent)
    /// Authenticated and decrypted, but the inner event could not be parsed. Answer `AckCode.malformed`.
    case malformedPayload
    /// Write `ControlMessage.authFailed`, disconnect, and skip this peripheral for the rest of the receiving session.
    /// Reported once; later messages produce `.none`.
    case authFailed
}

public struct MacHandshake: Sendable {
    private enum State: Sendable { case idle, awaitingReply, authenticated, failed }

    private let pairKey: SymmetricKey?
    private let macNonce: Data
    private var state: State
    private var eventCrypto: SessionCrypto?
    private var controlCrypto: SessionCrypto?
    /// The failure was already handed to the caller (a Mac built with a bad nonce reports it from `begin()`).
    private var failureReported = false

    /// - Parameters:
    ///   - pairKey: `nil` when the Mac holds no pairing (never paired or revoked): every `helloReply` fails.
    ///   - macNonce: a fresh `Pairing.randomNonce()` for this connection. Single-use: build a new reducer per connection.
    public init(pairKey: SymmetricKey?, macNonce: Data) {
        self.pairKey = pairKey
        self.macNonce = macNonce
        // A malformed own nonce fails closed rather than starting a handshake that cannot be checked.
        state = macNonce.count == Pairing.nonceLength ? .idle : .failed
    }

    /// True once the phone's proof verified.
    public var isAuthenticated: Bool { state == .authenticated }

    /// Starts the challenge once the keyboard link is ready.
    public mutating func begin() -> MacHandshakeOutput {
        guard state == .idle else { return state == .failed && !failureReported ? fail() : .none }
        state = .awaitingReply
        return .send(.hello(macNonce: macNonce))
    }

    /// The app name the Receiver may put in a `ReceiverStatus`: `nil` until the phone is verified.
    public func statusToSend(appName: String?) -> String? {
        state == .authenticated ? appName : nil
    }

    /// Before authentication only `pairOffer` and `helloReply` are acceptable; afterwards only `sealed`. A plaintext
    /// `event` is a protocol violation at every point.
    public mutating func receive(_ message: PeripheralMessage) -> MacHandshakeOutput {
        if state == .failed { return .none }
        switch message {
        case .event:
            return fail()
        case .pairOffer(let commitment):
            guard state != .authenticated, commitment.count == Pairing.commitmentLength else { return fail() }
            return .pairOffer(commitment: commitment)
        case .pairReveal(let publicKey):
            guard state != .authenticated, publicKey.count == Pairing.publicKeyLength,
                  (try? P256.KeyAgreement.PublicKey(x963Representation: publicKey)) != nil else { return fail() }
            return .pairReveal(publicKey: publicKey)
        case .helloReply(let phoneNonce, let proof):
            guard state == .awaitingReply, let pairKey,
                  Pairing.verifyPhoneProof(proof, key: pairKey, macNonce: macNonce, phoneNonce: phoneNonce) else { return fail() }
            eventCrypto = SessionCrypto(pairKey: pairKey, macNonce: macNonce, phoneNonce: phoneNonce, direction: .phoneToMac)
            controlCrypto = SessionCrypto(pairKey: pairKey, macNonce: macNonce, phoneNonce: phoneNonce, direction: .macToPhone)
            state = .authenticated
            return .authenticated(reply: .auth(proof: Pairing.macProof(key: pairKey, macNonce: macNonce, phoneNonce: phoneNonce)))
        case .sealed(let payload):
            guard state == .authenticated, let eventCrypto, let plain = try? eventCrypto.open(payload) else { return fail() }
            switch try? PeripheralCodec.decode(plain) {
            case .event(let event)?: return .event(event)
            case nil: return .malformedPayload
            default: return fail()
            }
        }
    }

    /// Wraps an `ack` or `status` for the wire. After authentication the Mac sends nothing else on `control` except
    /// `authFailed`; anything but `ack` and `status` is refused.
    public func sealControl(_ message: ControlMessage) throws -> ControlMessage {
        guard state == .authenticated, let controlCrypto else { throw HandshakeError.notAuthenticated }
        switch message {
        case .ack, .status: return .sealed(try controlCrypto.seal(ControlCodec.encode(message)))
        default: throw HandshakeError.invalidControlMessage
        }
    }

    private mutating func fail() -> MacHandshakeOutput {
        state = .failed
        eventCrypto = nil
        controlCrypto = nil
        failureReported = true
        return .authFailed
    }
}
