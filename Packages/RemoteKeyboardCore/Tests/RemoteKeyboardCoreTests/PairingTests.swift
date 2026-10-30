import CryptoKit
import XCTest
@testable import RemoteKeyboardCore

/// Fixed scalars keep every key deterministic, so "SAS differs" never depends on a lucky random draw.
func fixedPrivateKey(_ byte: UInt8) -> P256.KeyAgreement.PrivateKey {
    try! P256.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: byte, count: 32))
}

func publicData(_ key: P256.KeyAgreement.PrivateKey) -> Data { key.publicKey.x963Representation }

final class PairingTests: XCTestCase {
    private let mac = fixedPrivateKey(0x11)
    private let phone = fixedPrivateKey(0x22)
    private let attackerA = fixedPrivateKey(0x33)
    private let attackerB = fixedPrivateKey(0x44)

    private func macKey() throws -> SymmetricKey {
        try Pairing.sharedKey(myPrivate: mac, peerPublic: publicData(phone), macPublic: publicData(mac), phonePublic: publicData(phone))
    }

    private func phoneKey() throws -> SymmetricKey {
        try Pairing.sharedKey(myPrivate: phone, peerPublic: publicData(mac), macPublic: publicData(mac), phonePublic: publicData(phone))
    }

    private func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

    func testBothSidesDeriveSameKeyAndSAS() throws {
        let m = try macKey()
        let p = try phoneKey()
        XCTAssertEqual(bytes(m), bytes(p))
        XCTAssertEqual(bytes(m).count, 32)
        let sas = Pairing.sas(m)
        XCTAssertEqual(sas, Pairing.sas(p))
        XCTAssertEqual(sas.count, 6)
        XCTAssertTrue(sas.allSatisfy { $0.isASCII && $0.isNumber })
    }

    func testSASDiffersWhenPublicKeySwapped() throws {
        // The Mac believes the attacker's key A is the phone; the phone believes the attacker's key B is the Mac.
        let macSide = try Pairing.sharedKey(
            myPrivate: mac, peerPublic: publicData(attackerA), macPublic: publicData(mac), phonePublic: publicData(attackerA))
        let phoneSide = try Pairing.sharedKey(
            myPrivate: phone, peerPublic: publicData(attackerB), macPublic: publicData(attackerB), phonePublic: publicData(phone))
        XCTAssertNotEqual(bytes(macSide), bytes(phoneSide))
        XCTAssertNotEqual(Pairing.sas(macSide), Pairing.sas(phoneSide))
    }

    func testSharedKeyIsBoundToBothPublicKeys() throws {
        // Same ECDH secret, different transcript (info) gives a different key.
        let honest = try macKey()
        let relabelled = try Pairing.sharedKey(
            myPrivate: mac, peerPublic: publicData(phone), macPublic: publicData(attackerA), phonePublic: publicData(phone))
        XCTAssertNotEqual(bytes(honest), bytes(relabelled))
    }

    func testSASFormulaMatchesSpec() {
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: key, salt: Data(), info: Data("rk-sas".utf8), outputByteCount: 4).withUnsafeBytes { Array($0) }
        let value = okm.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
        let expected = String(value)
        XCTAssertEqual(Pairing.sas(key), String(repeating: "0", count: 6 - expected.count) + expected)
    }

    func testSASIsLeftPaddedToSixDigits() {
        // Across many keys at least one SAS has a leading zero, and all are exactly six digits.
        var sawLeadingZero = false
        for i in 0..<3000 {
            let sas = Pairing.sas(SymmetricKey(data: Data("k\(i)".utf8)))
            XCTAssertEqual(sas.count, 6)
            if sas.hasPrefix("0") { sawLeadingZero = true }
        }
        XCTAssertTrue(sawLeadingZero)
    }

    func testMalformedPeerPublicKeyThrows() {
        for bad in [Data(), Data(repeating: 4, count: 64), Data(repeating: 4, count: 65), Data(repeating: 0, count: 33)] {
            XCTAssertThrowsError(try Pairing.sharedKey(
                myPrivate: mac, peerPublic: bad, macPublic: publicData(mac), phonePublic: publicData(phone))) {
                XCTAssertEqual($0 as? PairingError, .invalidPublicKey)
            }
        }
    }

    func testMalformedTranscriptKeysThrow() {
        XCTAssertThrowsError(try Pairing.sharedKey(
            myPrivate: mac, peerPublic: publicData(phone), macPublic: Data([1, 2, 3]), phonePublic: publicData(phone))) {
            XCTAssertEqual($0 as? PairingError, .invalidPublicKey)
        }
        XCTAssertThrowsError(try Pairing.sharedKey(
            myPrivate: mac, peerPublic: publicData(phone), macPublic: publicData(mac), phonePublic: Data())) {
            XCTAssertEqual($0 as? PairingError, .invalidPublicKey)
        }
    }

    func testProofsAre32BytesAndDomainSeparated() throws {
        let key = try macKey()
        let macNonce = Data(repeating: 1, count: 16)
        let phoneNonce = Data(repeating: 2, count: 16)
        let phoneProof = Pairing.phoneProof(key: key, macNonce: macNonce, phoneNonce: phoneNonce)
        let macProof = Pairing.macProof(key: key, macNonce: macNonce, phoneNonce: phoneNonce)
        XCTAssertEqual(phoneProof.count, 32)
        XCTAssertEqual(macProof.count, 32)
        XCTAssertNotEqual(phoneProof, macProof)
    }

    func testProofMatchesSpecFormula() throws {
        let key = try macKey()
        let macNonce = Data(repeating: 1, count: 16)
        let phoneNonce = Data(repeating: 2, count: 16)
        let expected = Data(HMAC<SHA256>.authenticationCode(
            for: Data("phone".utf8) + macNonce + phoneNonce, using: key))
        XCTAssertEqual(Pairing.phoneProof(key: key, macNonce: macNonce, phoneNonce: phoneNonce), expected)
        let expectedMac = Data(HMAC<SHA256>.authenticationCode(
            for: Data("mac".utf8) + macNonce + phoneNonce, using: key))
        XCTAssertEqual(Pairing.macProof(key: key, macNonce: macNonce, phoneNonce: phoneNonce), expectedMac)
    }

    func testProofChangesWithEitherNonceOrKey() throws {
        let key = try macKey()
        let other = SymmetricKey(data: Data(repeating: 9, count: 32))
        let n1 = Data(repeating: 1, count: 16), n2 = Data(repeating: 2, count: 16), n3 = Data(repeating: 3, count: 16)
        let base = Pairing.phoneProof(key: key, macNonce: n1, phoneNonce: n2)
        XCTAssertNotEqual(base, Pairing.phoneProof(key: key, macNonce: n3, phoneNonce: n2))
        XCTAssertNotEqual(base, Pairing.phoneProof(key: key, macNonce: n1, phoneNonce: n3))
        XCTAssertNotEqual(base, Pairing.phoneProof(key: other, macNonce: n1, phoneNonce: n2))
    }

    func testVerifyAcceptsRightProofAndRejectsEverythingElse() throws {
        let key = try macKey()
        let macNonce = Data(repeating: 1, count: 16), phoneNonce = Data(repeating: 2, count: 16)
        let good = Pairing.phoneProof(key: key, macNonce: macNonce, phoneNonce: phoneNonce)
        XCTAssertTrue(Pairing.verifyPhoneProof(good, key: key, macNonce: macNonce, phoneNonce: phoneNonce))
        // Role confusion: a mac proof is not a phone proof.
        XCTAssertFalse(Pairing.verifyPhoneProof(
            Pairing.macProof(key: key, macNonce: macNonce, phoneNonce: phoneNonce), key: key, macNonce: macNonce, phoneNonce: phoneNonce))
        XCTAssertFalse(Pairing.verifyPhoneProof(good.dropLast(), key: key, macNonce: macNonce, phoneNonce: phoneNonce))
        XCTAssertFalse(Pairing.verifyPhoneProof(Data(), key: key, macNonce: macNonce, phoneNonce: phoneNonce))
        XCTAssertFalse(Pairing.verifyPhoneProof(good + [0], key: key, macNonce: macNonce, phoneNonce: phoneNonce))
        // Wrong nonce lengths never verify, even when the HMAC over those bytes would match.
        let shortNonce = Data(repeating: 1, count: 15)
        let shortProof = Pairing.phoneProof(key: key, macNonce: shortNonce, phoneNonce: phoneNonce)
        XCTAssertFalse(Pairing.verifyPhoneProof(shortProof, key: key, macNonce: shortNonce, phoneNonce: phoneNonce))
        let macGood = Pairing.macProof(key: key, macNonce: macNonce, phoneNonce: phoneNonce)
        XCTAssertTrue(Pairing.verifyMacProof(macGood, key: key, macNonce: macNonce, phoneNonce: phoneNonce))
        XCTAssertFalse(Pairing.verifyMacProof(good, key: key, macNonce: macNonce, phoneNonce: phoneNonce))
    }

    func testRandomNonceIs16BytesAndFresh() {
        let a = Pairing.randomNonce(), b = Pairing.randomNonce()
        XCTAssertEqual(a.count, Pairing.nonceLength)
        XCTAssertEqual(Pairing.nonceLength, 16)
        XCTAssertNotEqual(a, b)
    }

    func testPublicKeyDataIsX963() {
        XCTAssertEqual(Pairing.publicKeyData(mac), mac.publicKey.x963Representation)
        XCTAssertEqual(Pairing.publicKeyData(mac).count, 65)
    }
}

final class AppGroupTests: XCTestCase {
    func testIdentifiersAndKeys() {
        XCTAssertEqual(AppGroup.identifier, "group.com.ansonhui.remotekeyboard")
        XCTAssertEqual(AppGroup.keychainAccessGroup, AppGroup.identifier)
        XCTAssertEqual(AppGroup.Key.probe, "probe")
    }
}
