import CryptoKit
import Foundation

public enum SessionCryptoError: Error, Equatable, Sendable {
    /// Wrong key, wrong session, tampered or too-short input. The caller treats it as an authentication failure.
    case openFailed
    case sealFailed
}

/// ChaCha20-Poly1305 for one direction of one session. The session key mixes both handshake nonces and the direction
/// into the pair key, so ciphertext recorded in one session, or sent the other way, does not open.
///
/// - `.phoneToMac`: the `PeripheralCodec`-encoded event (`PeripheralMessage.sealed`).
/// - `.macToPhone`: the `ControlCodec`-encoded `ack` or `status` (`ControlMessage.sealed`).
///
/// Replay inside one session is not prevented here (random AEAD nonce, no counter): the Mac's `EventDeduplicator`
/// catches it. The same `eventId` is a duplicate; an id that was evicted from the window has a lower `seq` and is
/// answered `outOfOrder`.
public struct SessionCrypto: Sendable {
    public enum Direction: Sendable {
        case phoneToMac, macToPhone

        fileprivate var info: Data {
            switch self {
            case .phoneToMac: Data("rk-session-p2m".utf8)
            case .macToPhone: Data("rk-session-m2p".utf8)
            }
        }
    }

    private let key: SymmetricKey

    public init(pairKey: SymmetricKey, macNonce: Data, phoneNonce: Data, direction: Direction) {
        key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: pairKey, salt: Data(), info: direction.info + macNonce + phoneNonce, outputByteCount: 32)
    }

    /// Returns `nonce(12) ‖ ciphertext ‖ tag(16)`; the nonce is fresh random for every call.
    public func seal(_ plain: Data) throws -> Data {
        guard let box = try? ChaChaPoly.seal(plain, using: key) else { throw SessionCryptoError.sealFailed }
        return box.combined
    }

    public func open(_ sealed: Data) throws -> Data {
        guard let box = try? ChaChaPoly.SealedBox(combined: sealed), let plain = try? ChaChaPoly.open(box, using: key) else {
            throw SessionCryptoError.openFailed
        }
        return plain
    }
}
