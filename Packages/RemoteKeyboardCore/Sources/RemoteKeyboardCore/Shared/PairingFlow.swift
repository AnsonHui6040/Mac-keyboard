import CryptoKit
import Foundation

// Commit-then-reveal pairing, as two pure reducers. The order is what stops an active man in the middle from searching
// for a key with a matching 6-digit SAS:
//
//   iPhone → pairOffer(commitment)                          the host sees only a hash of the iPhone's key
//   host   → pairAccept(hostPublic, host identity)          the host's key is on the wire before the iPhone's key is
//   iPhone → pairReveal(phonePublic, phone identity)        the host checks the key against the commitment, then derives key and SAS
//
// Both sides then show `sas`; the pair key is stored only after both people confirm. Each side checks the identity it
// receives (docs/protocol/v4.md §5.2): a 16-byte id, a name of 1 to 32 UTF-8 bytes (never repaired, a bad one fails the
// pairing), a platform string the protocol lists, and a public key that is a valid point and not its own. Keys are injected,
// nothing here reads a clock or random source. A reducer serves one pairing attempt and is then dropped; failure is sticky.

public enum PhonePairingOutput: Equatable, Sendable {
    case none
    /// Notify this message to the host (`pairReveal`).
    case send(PeripheralMessage)
    case failed
}

public struct PhonePairing: Sendable {
    private enum State: Sendable { case awaitingAccept, revealed, failed }

    private let privateKey: P256.KeyAgreement.PrivateKey
    private let phoneIdentity: PhoneIdentity
    private var state = State.awaitingAccept
    public private(set) var pairKey: SymmetricKey?
    /// Set once the reveal went out; show it and ask for confirmation.
    public private(set) var sas: String?
    /// The host that answered, as it described itself; set together with `sas`.
    public private(set) var host: HostIdentity?

    /// - Parameters:
    ///   - privateKey: a fresh `P256.KeyAgreement.PrivateKey` generated at the start of this pairing attempt, never reused
    ///     across attempts. The commitment only binds the iPhone to a key it has not shown yet; with a reused key a man in
    ///     the middle could learn it from an earlier attempt and search for a matching SAS ahead of time.
    ///   - phone: this iPhone's identity as it will be sent: a valid id and a name already clamped to 32 bytes.
    public init(privateKey: P256.KeyAgreement.PrivateKey, phone: PhoneIdentity) {
        self.privateKey = privateKey
        phoneIdentity = phone
    }

    /// Step 1: the commitment to this side's public key.
    public var offer: PeripheralMessage {
        .pairOffer(commitment: Pairing.commitment(phonePublic: Pairing.publicKeyData(privateKey)))
    }

    public mutating func receive(_ message: ControlMessage) -> PhonePairingOutput {
        guard state != .failed else { return .none }
        guard case .pairAccept(let hostPublic, let hostIdentity) = message else { return .none }
        let phonePublic = Pairing.publicKeyData(privateKey)
        guard state == .awaitingAccept, hostIdentity.isValid,
              let key = try? Pairing.sharedKey(
                myPrivate: privateKey, peerPublic: hostPublic, hostPublic: hostPublic, phonePublic: phonePublic,
                host: hostIdentity, phone: phoneIdentity) else {
            state = .failed
            pairKey = nil
            sas = nil
            host = nil
            return .failed
        }
        pairKey = key
        sas = Pairing.sas(key)
        host = hostIdentity
        state = .revealed
        return .send(.pairReveal(publicKey: phonePublic, phone: phoneIdentity))
    }
}

public enum MacPairingOutput: Equatable, Sendable {
    /// Write this to `control` (`pairAccept`).
    case send(ControlMessage)
    /// The reveal matched the commitment; `sas`, `pairKey` and `phone` are available.
    case completed
    case failed
}

public struct MacPairing: Sendable {
    private enum State: Sendable { case idle, accepted, completed, failed }

    private let privateKey: P256.KeyAgreement.PrivateKey
    private let hostIdentity: HostIdentity
    private var state = State.idle
    private var commitment = Data()
    public private(set) var pairKey: SymmetricKey?
    /// Set once the iPhone's key was revealed and verified.
    public private(set) var sas: String?
    /// The phone that paired, as it described itself; set together with `sas`.
    public private(set) var phone: PhoneIdentity?

    /// - Parameters:
    ///   - privateKey: a fresh `P256.KeyAgreement.PrivateKey` generated at the start of this pairing attempt, never reused
    ///     across attempts. The host's key is on the wire before the iPhone's key is revealed; a key reused from an earlier
    ///     attempt would be known to an observer of that attempt, and the commitment would protect nothing.
    ///   - host: this host's identity as it will be sent: a valid id and a name already clamped to 32 bytes.
    public init(privateKey: P256.KeyAgreement.PrivateKey, host: HostIdentity) {
        self.privateKey = privateKey
        hostIdentity = host
    }

    public mutating func receive(_ message: PeripheralMessage) -> MacPairingOutput {
        if state == .failed { return .failed }
        switch message {
        case .pairOffer(let offered):
            guard state == .idle, offered.count == Pairing.commitmentLength else { return fail() }
            commitment = offered
            state = .accepted
            return .send(.pairAccept(publicKey: Pairing.publicKeyData(privateKey), host: hostIdentity))
        case .pairReveal(let phonePublic, let phoneIdentity):
            // A reveal is only processed after this side's key went out in `pairAccept`.
            guard state == .accepted, phoneIdentity.isValid, Pairing.verifyCommitment(commitment, phonePublic: phonePublic),
                  let key = try? Pairing.sharedKey(
                    myPrivate: privateKey, peerPublic: phonePublic, hostPublic: Pairing.publicKeyData(privateKey),
                    phonePublic: phonePublic, host: hostIdentity, phone: phoneIdentity) else { return fail() }
            pairKey = key
            sas = Pairing.sas(key)
            phone = phoneIdentity
            state = .completed
            return .completed
        default:
            return fail()
        }
    }

    private mutating func fail() -> MacPairingOutput {
        state = .failed
        pairKey = nil
        sas = nil
        phone = nil
        return .failed
    }
}
