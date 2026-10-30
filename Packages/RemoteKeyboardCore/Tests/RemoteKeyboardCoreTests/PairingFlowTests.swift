import CryptoKit
import XCTest
@testable import RemoteKeyboardCore

final class PairingFlowTests: XCTestCase {
    private func bytes(_ key: SymmetricKey?) -> Data? { key?.withUnsafeBytes { Data($0) } }

    /// Runs offer → accept → reveal and returns both reducers plus the Mac's outputs.
    private func run(phoneKey: UInt8 = 0x22, macKey: UInt8 = 0x11) -> (phone: PhonePairing, mac: MacPairing) {
        var phone = PhonePairing(privateKey: fixedPrivateKey(phoneKey))
        var mac = MacPairing(privateKey: fixedPrivateKey(macKey))
        guard case .send(let accept) = mac.receive(phone.offer), case .send(let reveal) = phone.receive(accept) else {
            XCTFail("flow must complete"); return (phone, mac)
        }
        XCTAssertEqual(mac.receive(reveal), .completed)
        return (phone, mac)
    }

    func testHappyPathBothSidesDeriveTheSameKeyAndSAS() throws {
        let (phone, mac) = run()
        let sas = try XCTUnwrap(phone.sas)
        XCTAssertEqual(sas, mac.sas)
        XCTAssertEqual(sas.count, 6)
        XCTAssertEqual(bytes(phone.pairKey), bytes(mac.pairKey))
        XCTAssertNotNil(bytes(mac.pairKey))
    }

    func testOfferCarriesOnlyTheCommitmentNotTheKey() throws {
        let phone = PhonePairing(privateKey: fixedPrivateKey(0x22))
        guard case .pairOffer(let c) = phone.offer else { return XCTFail() }
        XCTAssertEqual(c, Pairing.commitment(phonePublic: publicData(fixedPrivateKey(0x22))))
        let wire = try PeripheralCodec.encode(phone.offer)
        XCTAssertNil(wire.range(of: publicData(fixedPrivateKey(0x22))))
        XCTAssertNil(wire.range(of: publicData(fixedPrivateKey(0x22)).base64EncodedData()))
    }

    func testRevealNotMatchingCommitmentIsRejected() {
        // An active attacker saw the commitment, then tries to reveal a key it ground out to give a matching SAS.
        var mac = MacPairing(privateKey: fixedPrivateKey(0x11))
        let phone = PhonePairing(privateKey: fixedPrivateKey(0x22))
        guard case .send = mac.receive(phone.offer) else { return XCTFail() }
        let forged = PeripheralMessage.pairReveal(publicKey: publicData(fixedPrivateKey(0x66)))
        XCTAssertEqual(mac.receive(forged), .failed)
        XCTAssertNil(mac.sas)
        XCTAssertNil(mac.pairKey)
        // Sticky: the honest reveal afterwards does not rescue the session.
        XCTAssertNotEqual(mac.receive(.pairReveal(publicKey: publicData(fixedPrivateKey(0x22)))), .completed)
        XCTAssertNil(mac.pairKey)
    }

    func testMacCannotSeePhoneKeyBeforeCommittingItsOwn() {
        // A reveal with nothing committed and nothing accepted is rejected, key or not.
        var early = MacPairing(privateKey: fixedPrivateKey(0x11))
        XCTAssertEqual(early.receive(.pairReveal(publicKey: publicData(fixedPrivateKey(0x22)))), .failed)
        XCTAssertNil(early.sas)

        // Only after the Mac's own key went out in `pairAccept` is a reveal processed.
        var mac = MacPairing(privateKey: fixedPrivateKey(0x11))
        let phone = PhonePairing(privateKey: fixedPrivateKey(0x22))
        XCTAssertNil(mac.sas)
        XCTAssertEqual(mac.receive(phone.offer), .send(.pairAccept(publicKey: publicData(fixedPrivateKey(0x11)))))
        XCTAssertNil(mac.sas, "no SAS before the reveal")
        XCTAssertEqual(mac.receive(.pairReveal(publicKey: publicData(fixedPrivateKey(0x22)))), .completed)
    }

    func testPhoneDoesNotRevealUntilTheMacAccepted() {
        var phone = PhonePairing(privateKey: fixedPrivateKey(0x22))
        XCTAssertNil(phone.sas)
        // Nothing but pairAccept moves the phone, and it never reveals on its own.
        XCTAssertEqual(phone.receive(.hello(macNonce: Data(repeating: 1, count: 16))), .none)
        XCTAssertNil(phone.sas)
        guard case .send(.pairReveal(let key)) = phone.receive(.pairAccept(publicKey: publicData(fixedPrivateKey(0x11)))) else {
            return XCTFail()
        }
        XCTAssertEqual(key, publicData(fixedPrivateKey(0x22)))
        XCTAssertNotNil(phone.sas)
    }

    func testPhoneRejectsAnInvalidOrReflectedMacKeyAndASecondAccept() {
        var bad = PhonePairing(privateKey: fixedPrivateKey(0x22))
        XCTAssertEqual(bad.receive(.pairAccept(publicKey: Data(repeating: 4, count: 65))), .failed)
        XCTAssertNil(bad.pairKey)
        var reflected = PhonePairing(privateKey: fixedPrivateKey(0x22))
        XCTAssertEqual(reflected.receive(.pairAccept(publicKey: publicData(fixedPrivateKey(0x22)))), .failed)
        var twice = PhonePairing(privateKey: fixedPrivateKey(0x22))
        _ = twice.receive(.pairAccept(publicKey: publicData(fixedPrivateKey(0x11))))
        XCTAssertEqual(twice.receive(.pairAccept(publicKey: publicData(fixedPrivateKey(0x33)))), .failed)
    }

    func testMacRejectsBadCommitmentSecondOfferAndInvalidReveal() {
        var shortCommit = MacPairing(privateKey: fixedPrivateKey(0x11))
        XCTAssertEqual(shortCommit.receive(.pairOffer(commitment: Data(repeating: 1, count: 31))), .failed)
        var mac = MacPairing(privateKey: fixedPrivateKey(0x11))
        let phone = PhonePairing(privateKey: fixedPrivateKey(0x22))
        _ = mac.receive(phone.offer)
        XCTAssertEqual(mac.receive(phone.offer), .failed)
        var invalid = MacPairing(privateKey: fixedPrivateKey(0x11))
        _ = invalid.receive(phone.offer)
        XCTAssertEqual(invalid.receive(.pairReveal(publicKey: Data(repeating: 4, count: 65))), .failed)
        var other = MacPairing(privateKey: fixedPrivateKey(0x11))
        XCTAssertEqual(other.receive(.sealed(Data())), .failed)
    }

    func testMITMGivesDifferentSASOnEachSide() throws {
        // Attacker answers the phone with its own key; the Mac got the real commitment/reveal, but the phone's key
        // in the phone's transcript is paired with the attacker's key.
        var phone = PhonePairing(privateKey: fixedPrivateKey(0x22))
        var mac = MacPairing(privateKey: fixedPrivateKey(0x11))
        guard case .send = mac.receive(phone.offer) else { return XCTFail() }
        _ = phone.receive(.pairAccept(publicKey: publicData(fixedPrivateKey(0x77))))
        XCTAssertEqual(mac.receive(.pairReveal(publicKey: publicData(fixedPrivateKey(0x22)))), .completed)
        XCTAssertNotEqual(phone.sas, mac.sas)
    }
}
