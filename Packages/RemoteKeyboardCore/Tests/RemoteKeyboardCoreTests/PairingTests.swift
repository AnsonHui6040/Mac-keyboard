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
        try Pairing.sharedKey(myPrivate: mac, peerPublic: publicData(phone), hostPublic: publicData(mac), phonePublic: publicData(phone))
    }

    private func phoneKey() throws -> SymmetricKey {
        try Pairing.sharedKey(myPrivate: phone, peerPublic: publicData(mac), hostPublic: publicData(mac), phonePublic: publicData(phone))
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
            myPrivate: mac, peerPublic: publicData(attackerA), hostPublic: publicData(mac), phonePublic: publicData(attackerA))
        let phoneSide = try Pairing.sharedKey(
            myPrivate: phone, peerPublic: publicData(attackerB), hostPublic: publicData(attackerB), phonePublic: publicData(phone))
        XCTAssertNotEqual(bytes(macSide), bytes(phoneSide))
        XCTAssertNotEqual(Pairing.sas(macSide), Pairing.sas(phoneSide))
    }

    func testSharedKeyRejectsATranscriptThatDoesNotContainMyOwnKey() {
        // Same ECDH secret, but the transcript names the attacker's key instead of mine.
        XCTAssertThrowsError(try Pairing.sharedKey(
            myPrivate: mac, peerPublic: publicData(phone), hostPublic: publicData(attackerA), phonePublic: publicData(phone))) {
            XCTAssertEqual($0 as? PairingError, .invalidPublicKey)
        }
        // The transcript must be exactly {mine, peer}: a third key in either slot is rejected.
        XCTAssertThrowsError(try Pairing.sharedKey(
            myPrivate: mac, peerPublic: publicData(phone), hostPublic: publicData(mac), phonePublic: publicData(attackerA))) {
            XCTAssertEqual($0 as? PairingError, .invalidPublicKey)
        }
    }

    func testSharedKeyRejectsReflectedOwnKeyAsPeer() {
        XCTAssertThrowsError(try Pairing.sharedKey(
            myPrivate: mac, peerPublic: publicData(mac), hostPublic: publicData(mac), phonePublic: publicData(mac))) {
            XCTAssertEqual($0 as? PairingError, .invalidPublicKey)
        }
    }

    func testSharedKeyWorksInEitherRoleOrder() throws {
        // The roles are decided by the transcript slots, not by who calls.
        XCTAssertEqual(bytes(try macKey()), bytes(try phoneKey()))
    }

    func testCommitmentIsSHA256OfLabelAndKey() {
        let key = publicData(phone)
        let c = Pairing.commitment(phonePublic: key)
        XCTAssertEqual(c.count, 32)
        XCTAssertEqual(c, Data(SHA256.hash(data: Data("rk-commit".utf8) + key)))
        XCTAssertNotEqual(c, Pairing.commitment(phonePublic: publicData(attackerA)))
    }

    func testVerifyCommitment() {
        let key = publicData(phone)
        let c = Pairing.commitment(phonePublic: key)
        XCTAssertTrue(Pairing.verifyCommitment(c, phonePublic: key))
        XCTAssertFalse(Pairing.verifyCommitment(c, phonePublic: publicData(attackerA)))
        XCTAssertFalse(Pairing.verifyCommitment(c.dropLast(), phonePublic: key))
        XCTAssertFalse(Pairing.verifyCommitment(Data(), phonePublic: key))
        XCTAssertFalse(Pairing.verifyCommitment(c + [0], phonePublic: key))
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
                myPrivate: mac, peerPublic: bad, hostPublic: publicData(mac), phonePublic: publicData(phone))) {
                XCTAssertEqual($0 as? PairingError, .invalidPublicKey)
            }
        }
    }

    func testMalformedTranscriptKeysThrow() {
        XCTAssertThrowsError(try Pairing.sharedKey(
            myPrivate: mac, peerPublic: publicData(phone), hostPublic: Data([1, 2, 3]), phonePublic: publicData(phone))) {
            XCTAssertEqual($0 as? PairingError, .invalidPublicKey)
        }
        XCTAssertThrowsError(try Pairing.sharedKey(
            myPrivate: mac, peerPublic: publicData(phone), hostPublic: publicData(mac), phonePublic: Data())) {
            XCTAssertEqual($0 as? PairingError, .invalidPublicKey)
        }
    }

    func testProofsAre32BytesAndDomainSeparated() throws {
        let key = try macKey()
        let hostNonce = Data(repeating: 1, count: 16)
        let phoneNonce = Data(repeating: 2, count: 16)
        let phoneProof = Pairing.phoneProof(key: key, hostNonce: hostNonce, phoneNonce: phoneNonce)
        let hostProof = Pairing.hostProof(key: key, hostNonce: hostNonce, phoneNonce: phoneNonce)
        XCTAssertEqual(phoneProof.count, 32)
        XCTAssertEqual(hostProof.count, 32)
        XCTAssertNotEqual(phoneProof, hostProof)
    }

    func testProofLabelsAreDistinct() throws {
        let key = try macKey()
        let h = Data(repeating: 1, count: 16), p = Data(repeating: 2, count: 16)
        XCTAssertNotEqual(Pairing.phoneProof(key: key, hostNonce: h, phoneNonce: p), Pairing.hostProof(key: key, hostNonce: h, phoneNonce: p))
        XCTAssertEqual(
            Pairing.hostProof(key: key, hostNonce: h, phoneNonce: p),
            Data(HMAC<SHA256>.authenticationCode(for: Data("host".utf8) + h + p, using: key)))
    }

    // MARK: Identities enter the key

    private func derive(host: HostIdentity = Fixture.hostIdentity, phoneId: PhoneIdentity = Fixture.phoneIdentity) throws -> Data {
        bytes(try Pairing.sharedKey(
            myPrivate: mac, peerPublic: publicData(phone), hostPublic: publicData(mac), phonePublic: publicData(phone),
            host: host, phone: phoneId))
    }

    func testSharedKeyChangesWhenHostNameChanges() throws {
        let base = try derive()
        let renamed = HostIdentity(id: Fixture.hostId, name: "書房的 Mac ", platform: .mac)
        XCTAssertNotEqual(base, try derive(host: renamed))
        XCTAssertEqual(base, try derive(host: Fixture.hostIdentity), "same input, same key")
    }

    func testSharedKeyChangesWhenHostPlatformChanges() throws {
        XCTAssertNotEqual(
            try derive(), try derive(host: HostIdentity(id: Fixture.hostId, name: Fixture.hostIdentity.name, platform: .linux)))
        XCTAssertNotEqual(
            try derive(), try derive(host: HostIdentity(id: Data(repeating: 9, count: 16), name: Fixture.hostIdentity.name, platform: .mac)))
    }

    func testSharedKeyChangesWhenPhoneIdentityChanges() throws {
        let base = try derive()
        XCTAssertNotEqual(base, try derive(phoneId: PhoneIdentity(id: Fixture.phoneId, name: "Anson", platform: .ios)))
        XCTAssertNotEqual(base, try derive(phoneId: PhoneIdentity(id: Fixture.phoneId, name: Fixture.phoneIdentity.name, platform: .android)))
        XCTAssertNotEqual(base, try derive(phoneId: PhoneIdentity(id: Data(repeating: 9, count: 16), name: Fixture.phoneIdentity.name, platform: .ios)))
    }

    func testSharedKeyRejectsWrongIdLengths() {
        let badHost = HostIdentity(id: Data(repeating: 1, count: 15), name: "H", platform: .mac)
        XCTAssertThrowsError(try derive(host: badHost)) { XCTAssertEqual($0 as? PairingError, .invalidIdentity) }
    }

    func testPairSaltIsV2() throws {
        // The info and salt are fixed by docs/protocol/v4.md §5.3; recompute the key by hand.
        let z = try mac.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: publicData(phone)))
        func digest(_ identity: (String, String)) -> Data {
            Data(SHA256.hash(data: Data(identity.0.utf8) + [0] + Data(identity.1.utf8)))
        }
        let info = publicData(mac) + publicData(phone) + Fixture.hostId + digest(("書房的 Mac", "mac"))
            + Fixture.phoneId + digest(("Anson 的 iPhone", "ios"))
        XCTAssertEqual(info.count, 226)
        let expected = z.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("rk-pair-v2".utf8), sharedInfo: info, outputByteCount: 32)
        XCTAssertEqual(bytes(expected), try derive())
    }

    func testProofMatchesSpecFormula() throws {
        let key = try macKey()
        let hostNonce = Data(repeating: 1, count: 16)
        let phoneNonce = Data(repeating: 2, count: 16)
        let expected = Data(HMAC<SHA256>.authenticationCode(
            for: Data("phone".utf8) + hostNonce + phoneNonce, using: key))
        XCTAssertEqual(Pairing.phoneProof(key: key, hostNonce: hostNonce, phoneNonce: phoneNonce), expected)
        let expectedMac = Data(HMAC<SHA256>.authenticationCode(
            for: Data("host".utf8) + hostNonce + phoneNonce, using: key))
        XCTAssertEqual(Pairing.hostProof(key: key, hostNonce: hostNonce, phoneNonce: phoneNonce), expectedMac)
    }

    func testProofChangesWithEitherNonceOrKey() throws {
        let key = try macKey()
        let other = SymmetricKey(data: Data(repeating: 9, count: 32))
        let n1 = Data(repeating: 1, count: 16), n2 = Data(repeating: 2, count: 16), n3 = Data(repeating: 3, count: 16)
        let base = Pairing.phoneProof(key: key, hostNonce: n1, phoneNonce: n2)
        XCTAssertNotEqual(base, Pairing.phoneProof(key: key, hostNonce: n3, phoneNonce: n2))
        XCTAssertNotEqual(base, Pairing.phoneProof(key: key, hostNonce: n1, phoneNonce: n3))
        XCTAssertNotEqual(base, Pairing.phoneProof(key: other, hostNonce: n1, phoneNonce: n2))
    }

    func testVerifyAcceptsRightProofAndRejectsEverythingElse() throws {
        let key = try macKey()
        let hostNonce = Data(repeating: 1, count: 16), phoneNonce = Data(repeating: 2, count: 16)
        let good = Pairing.phoneProof(key: key, hostNonce: hostNonce, phoneNonce: phoneNonce)
        XCTAssertTrue(Pairing.verifyPhoneProof(good, key: key, hostNonce: hostNonce, phoneNonce: phoneNonce))
        // Role confusion: a mac proof is not a phone proof.
        XCTAssertFalse(Pairing.verifyPhoneProof(
            Pairing.hostProof(key: key, hostNonce: hostNonce, phoneNonce: phoneNonce), key: key, hostNonce: hostNonce, phoneNonce: phoneNonce))
        XCTAssertFalse(Pairing.verifyPhoneProof(good.dropLast(), key: key, hostNonce: hostNonce, phoneNonce: phoneNonce))
        XCTAssertFalse(Pairing.verifyPhoneProof(Data(), key: key, hostNonce: hostNonce, phoneNonce: phoneNonce))
        XCTAssertFalse(Pairing.verifyPhoneProof(good + [0], key: key, hostNonce: hostNonce, phoneNonce: phoneNonce))
        // Wrong nonce lengths never verify, even when the HMAC over those bytes would match.
        let shortNonce = Data(repeating: 1, count: 15)
        let shortProof = Pairing.phoneProof(key: key, hostNonce: shortNonce, phoneNonce: phoneNonce)
        XCTAssertFalse(Pairing.verifyPhoneProof(shortProof, key: key, hostNonce: shortNonce, phoneNonce: phoneNonce))
        let macGood = Pairing.hostProof(key: key, hostNonce: hostNonce, phoneNonce: phoneNonce)
        XCTAssertTrue(Pairing.verifyHostProof(macGood, key: key, hostNonce: hostNonce, phoneNonce: phoneNonce))
        XCTAssertFalse(Pairing.verifyHostProof(good, key: key, hostNonce: hostNonce, phoneNonce: phoneNonce))
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
