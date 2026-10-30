import CryptoKit
import Foundation

public enum PairingError: Error, Equatable, Sendable {
    /// A public key that is not a valid 65-byte x9.63 P-256 point.
    case invalidPublicKey
}

/// Key agreement, short authentication string and challenge proofs. Pure functions over CryptoKit; nothing here reads
/// a clock or a global random source except `randomNonce()`.
public enum Pairing {
    public static let nonceLength = 16
    public static let proofLength = 32
    static let publicKeyLength = 65

    private static let pairSalt = Data("rk-pair-v1".utf8)
    private static let sasInfo = Data("rk-sas".utf8)
    private static let phoneLabel = Data("phone".utf8)
    private static let macLabel = Data("mac".utf8)

    /// A public key as it travels: the x9.63 representation, 65 bytes.
    public static func publicKeyData(_ key: P256.KeyAgreement.PrivateKey) -> Data {
        key.publicKey.x963Representation
    }

    /// 16 fresh bytes from the system random source.
    public static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<nonceLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// ECDH followed by HKDF-SHA256 (salt `rk-pair-v1`, info = macPublic ‖ phonePublic, 32 bytes). Binding both public
    /// keys into the info makes a swapped key show up as a different key and a different SAS.
    public static func sharedKey(
        myPrivate: P256.KeyAgreement.PrivateKey, peerPublic: Data, macPublic: Data, phonePublic: Data
    ) throws -> SymmetricKey {
        guard macPublic.count == publicKeyLength, phonePublic.count == publicKeyLength,
              let peer = try? P256.KeyAgreement.PublicKey(x963Representation: peerPublic),
              let secret = try? myPrivate.sharedSecretFromKeyAgreement(with: peer) else {
            throw PairingError.invalidPublicKey
        }
        return secret.hkdfDerivedSymmetricKey(
            using: SHA256.self, salt: pairSalt, sharedInfo: macPublic + phonePublic, outputByteCount: 32)
    }

    /// Six decimal digits both people compare on screen: the first four bytes of HKDF(key, info `rk-sas`) as a
    /// big-endian UInt32, modulo 1 000 000, left-padded with zeros.
    public static func sas(_ key: SymmetricKey) -> String {
        let bytes = HKDF<SHA256>.deriveKey(inputKeyMaterial: key, salt: Data(), info: sasInfo, outputByteCount: 4)
            .withUnsafeBytes { Array($0) }
        let value = bytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        let digits = String(value)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }

    /// HMAC-SHA256(key, `phone` ‖ macNonce ‖ phoneNonce).
    public static func phoneProof(key: SymmetricKey, macNonce: Data, phoneNonce: Data) -> Data {
        proof(label: phoneLabel, key: key, macNonce: macNonce, phoneNonce: phoneNonce)
    }

    /// HMAC-SHA256(key, `mac` ‖ macNonce ‖ phoneNonce).
    public static func macProof(key: SymmetricKey, macNonce: Data, phoneNonce: Data) -> Data {
        proof(label: macLabel, key: key, macNonce: macNonce, phoneNonce: phoneNonce)
    }

    /// Constant-time check. Wrong nonce or proof lengths are rejected before any comparison.
    public static func verifyPhoneProof(_ proof: Data, key: SymmetricKey, macNonce: Data, phoneNonce: Data) -> Bool {
        verify(proof, label: phoneLabel, key: key, macNonce: macNonce, phoneNonce: phoneNonce)
    }

    public static func verifyMacProof(_ proof: Data, key: SymmetricKey, macNonce: Data, phoneNonce: Data) -> Bool {
        verify(proof, label: macLabel, key: key, macNonce: macNonce, phoneNonce: phoneNonce)
    }

    private static func proof(label: Data, key: SymmetricKey, macNonce: Data, phoneNonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: label + macNonce + phoneNonce, using: key))
    }

    private static func verify(_ proof: Data, label: Data, key: SymmetricKey, macNonce: Data, phoneNonce: Data) -> Bool {
        guard macNonce.count == nonceLength, phoneNonce.count == nonceLength, proof.count == proofLength else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: label + macNonce + phoneNonce, using: key)
    }
}
