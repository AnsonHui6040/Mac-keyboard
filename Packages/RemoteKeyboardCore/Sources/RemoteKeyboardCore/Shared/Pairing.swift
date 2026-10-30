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
    private static let commitLabel = Data("rk-commit".utf8)
    public static let commitmentLength = 32

    /// A public key as it travels: the x9.63 representation, 65 bytes.
    public static func publicKeyData(_ key: P256.KeyAgreement.PrivateKey) -> Data {
        key.publicKey.x963Representation
    }

    /// 16 fresh bytes from the system random source.
    public static func randomNonce() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<nonceLength).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// SHA-256(`rk-commit` ‖ phonePublic x9.63). The iPhone sends this in `pairOffer` and reveals the key only after the
    /// Mac's key is on the wire, so nobody can grind a key whose 6-digit SAS matches after seeing the other side's key.
    public static func commitment(phonePublic: Data) -> Data {
        Data(SHA256.hash(data: commitLabel + phonePublic))
    }

    /// Constant-time check of a revealed key against the commitment.
    public static func verifyCommitment(_ commitment: Data, phonePublic: Data) -> Bool {
        guard commitment.count == commitmentLength else { return false }
        let expected = Self.commitment(phonePublic: phonePublic)
        var difference: UInt8 = 0
        for (a, b) in zip(commitment, expected) { difference |= a ^ b }
        return difference == 0
    }

    /// ECDH followed by HKDF-SHA256 (salt `rk-pair-v1`, info = macPublic ‖ phonePublic, 32 bytes). Binding both public
    /// keys into the info makes a swapped key show up as a different key and a different SAS.
    /// The transcript must be exactly {my own public key, `peerPublic`} in one of the two slots, and the peer's key must
    /// not be mine; anything else throws `.invalidPublicKey`.
    public static func sharedKey(
        myPrivate: P256.KeyAgreement.PrivateKey, peerPublic: Data, macPublic: Data, phonePublic: Data
    ) throws -> SymmetricKey {
        let mine = myPrivate.publicKey.x963Representation
        let ownsOneSlot = (mine == macPublic && peerPublic == phonePublic) || (mine == phonePublic && peerPublic == macPublic)
        guard ownsOneSlot, peerPublic != mine, macPublic.count == publicKeyLength, phonePublic.count == publicKeyLength,
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
