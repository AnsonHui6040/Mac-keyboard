import CryptoKit
import Foundation

public enum SessionCryptoError: Error, Equatable, Sendable {
    /// Wrong key, wrong session, tampered or too-short input. The caller treats it as an authentication failure.
    case openFailed
    case sealFailed
}

/// ChaCha20-Poly1305 over the bytes of one `PeripheralCodec`-encoded event. The session key mixes both handshake
/// nonces into the pair key, so a sealed event recorded in one session does not open in another.
public struct SessionCrypto: Sendable {
    private static let info = Data("rk-session".utf8)
    private let key: SymmetricKey

    public init(pairKey: SymmetricKey, macNonce: Data, phoneNonce: Data) {
        key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: pairKey, salt: Data(), info: Self.info + macNonce + phoneNonce, outputByteCount: 32)
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
