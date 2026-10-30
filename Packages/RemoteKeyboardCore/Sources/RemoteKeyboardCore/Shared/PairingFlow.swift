import CryptoKit
import Foundation

// Commit-then-reveal pairing, as two pure reducers. The order is what stops an active man in the middle from searching
// for a key with a matching 6-digit SAS:
//
//   iPhone → pairOffer(commitment)     the Mac sees only a hash of the iPhone's key
//   Mac    → pairAccept(macPublic)     the Mac's key is on the wire before the iPhone's key is
//   iPhone → pairReveal(phonePublic)   the Mac checks it against the commitment, then derives key and SAS
//
// Both sides then show `sas`; the pair key is stored only after both people confirm. Keys are injected, nothing here reads
// a clock or random source. A reducer serves one pairing attempt and is then dropped; failure is sticky.

public enum PhonePairingOutput: Equatable, Sendable {
    case none
    /// Notify this message to the Mac (`pairReveal`).
    case send(PeripheralMessage)
    case failed
}

public struct PhonePairing: Sendable {
    private enum State: Sendable { case awaitingAccept, revealed, failed }

    private let privateKey: P256.KeyAgreement.PrivateKey
    private var state = State.awaitingAccept
    public private(set) var pairKey: SymmetricKey?
    /// Set once the reveal went out; show it and ask for confirmation.
    public private(set) var sas: String?

    /// - Parameter privateKey: a fresh `P256.KeyAgreement.PrivateKey` generated at the start of this pairing attempt, never
    ///   reused across attempts. The commitment only binds the iPhone to a key it has not shown yet; with a reused key a
    ///   man in the middle could learn it from an earlier attempt and search for a matching SAS ahead of time.
    public init(privateKey: P256.KeyAgreement.PrivateKey) { self.privateKey = privateKey }

    /// Step 1: the commitment to this side's public key.
    public var offer: PeripheralMessage {
        .pairOffer(commitment: Pairing.commitment(phonePublic: Pairing.publicKeyData(privateKey)))
    }

    public mutating func receive(_ message: ControlMessage) -> PhonePairingOutput {
        guard state != .failed else { return .none }
        guard case .pairAccept(let macPublic) = message else { return .none }
        let phonePublic = Pairing.publicKeyData(privateKey)
        guard state == .awaitingAccept,
              let key = try? Pairing.sharedKey(
                myPrivate: privateKey, peerPublic: macPublic, macPublic: macPublic, phonePublic: phonePublic) else {
            state = .failed
            pairKey = nil
            sas = nil
            return .failed
        }
        pairKey = key
        sas = Pairing.sas(key)
        state = .revealed
        return .send(.pairReveal(publicKey: phonePublic))
    }
}

public enum MacPairingOutput: Equatable, Sendable {
    /// Write this to `control` (`pairAccept`).
    case send(ControlMessage)
    /// The reveal matched the commitment; `sas` and `pairKey` are available.
    case completed
    case failed
}

public struct MacPairing: Sendable {
    private enum State: Sendable { case idle, accepted, completed, failed }

    private let privateKey: P256.KeyAgreement.PrivateKey
    private var state = State.idle
    private var commitment = Data()
    public private(set) var pairKey: SymmetricKey?
    /// Set once the iPhone's key was revealed and verified.
    public private(set) var sas: String?

    /// - Parameter privateKey: a fresh `P256.KeyAgreement.PrivateKey` generated at the start of this pairing attempt, never
    ///   reused across attempts. The Mac's key is on the wire before the iPhone's key is revealed; a key reused from an
    ///   earlier attempt would be known to an observer of that attempt, and the commitment would protect nothing.
    public init(privateKey: P256.KeyAgreement.PrivateKey) { self.privateKey = privateKey }

    public mutating func receive(_ message: PeripheralMessage) -> MacPairingOutput {
        if state == .failed { return .failed }
        switch message {
        case .pairOffer(let offered):
            guard state == .idle, offered.count == Pairing.commitmentLength else { return fail() }
            commitment = offered
            state = .accepted
            return .send(.pairAccept(publicKey: Pairing.publicKeyData(privateKey)))
        case .pairReveal(let phonePublic):
            // A reveal is only processed after this side's key went out in `pairAccept`.
            guard state == .accepted, Pairing.verifyCommitment(commitment, phonePublic: phonePublic),
                  let key = try? Pairing.sharedKey(
                    myPrivate: privateKey, peerPublic: phonePublic, macPublic: Pairing.publicKeyData(privateKey),
                    phonePublic: phonePublic) else { return fail() }
            pairKey = key
            sas = Pairing.sas(key)
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
        return .failed
    }
}
