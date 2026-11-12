import CryptoKit
import XCTest
@testable import RemoteKeyboardCore

final class PairingFlowTests: XCTestCase {
    private let host = Fixture.hostIdentity
    private let phoneIdentity = Fixture.phoneIdentity

    private func bytes(_ key: SymmetricKey?) -> Data? { key?.withUnsafeBytes { Data($0) } }

    private func newPhone(_ key: UInt8 = 0x22, identity: PhoneIdentity? = nil) -> PhonePairing {
        PhonePairing(privateKey: fixedPrivateKey(key), phone: identity ?? phoneIdentity)
    }

    private func newMac(_ key: UInt8 = 0x11, identity: HostIdentity? = nil) -> MacPairing {
        MacPairing(privateKey: fixedPrivateKey(key), host: identity ?? host)
    }

    /// Runs offer → accept → reveal and returns both reducers.
    private func run(phoneKey: UInt8 = 0x22, macKey: UInt8 = 0x11) -> (phone: PhonePairing, mac: MacPairing) {
        var phone = newPhone(phoneKey)
        var mac = newMac(macKey)
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

    func testPairingCarriesBothIdentities() throws {
        let (phone, mac) = run()
        XCTAssertEqual(phone.host, host)
        XCTAssertEqual(mac.phone, phoneIdentity)
        XCTAssertEqual(bytes(phone.pairKey), bytes(mac.pairKey))
        XCTAssertEqual(phone.sas, mac.sas)
        // Nothing is known before the messages arrive.
        XCTAssertNil(newPhone().host)
        XCTAssertNil(newMac().phone)
    }

    func testTamperedHostNameGivesDifferentSAS() throws {
        var phone = newPhone()
        var mac = newMac()
        guard case .send(.pairAccept(let key, _)) = mac.receive(phone.offer) else { return XCTFail() }
        // A man in the middle keeps the key but renames the host on its way to the phone.
        let renamed = HostIdentity(id: host.id, name: "別的電腦", platform: host.platform)
        guard case .send(let reveal) = phone.receive(.pairAccept(publicKey: key, host: renamed)) else { return XCTFail() }
        XCTAssertEqual(mac.receive(reveal), .completed)
        XCTAssertNotEqual(phone.sas, mac.sas)
        XCTAssertNotEqual(bytes(phone.pairKey), bytes(mac.pairKey))
    }

    func testTamperedPhoneNameGivesDifferentSAS() throws {
        var phone = newPhone()
        var mac = newMac()
        guard case .send(let accept) = mac.receive(phone.offer), case .send(.pairReveal(let key, _)) = phone.receive(accept) else {
            return XCTFail()
        }
        let renamed = PhoneIdentity(id: phoneIdentity.id, name: "別的手機", platform: phoneIdentity.platform)
        XCTAssertEqual(mac.receive(.pairReveal(publicKey: key, phone: renamed)), .completed)
        XCTAssertNotEqual(phone.sas, mac.sas)
    }

    func testOfferCarriesOnlyTheCommitmentNotTheKey() throws {
        let phone = newPhone()
        guard case .pairOffer(let c) = phone.offer else { return XCTFail() }
        XCTAssertEqual(c, Pairing.commitment(phonePublic: publicData(fixedPrivateKey(0x22))))
        let wire = try PeripheralCodec.encode(phone.offer)
        XCTAssertNil(wire.range(of: publicData(fixedPrivateKey(0x22))))
        XCTAssertNil(wire.range(of: publicData(fixedPrivateKey(0x22)).base64EncodedData()))
    }

    func testRevealNotMatchingCommitmentIsRejected() {
        // An active attacker saw the commitment, then tries to reveal a key it ground out to give a matching SAS.
        var mac = newMac()
        let phone = newPhone()
        guard case .send = mac.receive(phone.offer) else { return XCTFail() }
        let forged = PeripheralMessage.pairReveal(publicKey: publicData(fixedPrivateKey(0x66)), phone: phoneIdentity)
        XCTAssertEqual(mac.receive(forged), .failed)
        XCTAssertNil(mac.sas)
        XCTAssertNil(mac.pairKey)
        XCTAssertNil(mac.phone)
        // Sticky: the honest reveal afterwards does not rescue the session.
        XCTAssertNotEqual(
            mac.receive(.pairReveal(publicKey: publicData(fixedPrivateKey(0x22)), phone: phoneIdentity)), .completed)
        XCTAssertNil(mac.pairKey)
    }

    func testHostCannotSeePhoneKeyBeforeCommittingItsOwn() {
        // A reveal with nothing committed and nothing accepted is rejected, key or not.
        var early = newMac()
        XCTAssertEqual(
            early.receive(.pairReveal(publicKey: publicData(fixedPrivateKey(0x22)), phone: phoneIdentity)), .failed)
        XCTAssertNil(early.sas)

        // Only after the host's own key went out in `pairAccept` is a reveal processed.
        var mac = newMac()
        let phone = newPhone()
        XCTAssertNil(mac.sas)
        XCTAssertEqual(
            mac.receive(phone.offer), .send(.pairAccept(publicKey: publicData(fixedPrivateKey(0x11)), host: host)))
        XCTAssertNil(mac.sas, "no SAS before the reveal")
        XCTAssertEqual(
            mac.receive(.pairReveal(publicKey: publicData(fixedPrivateKey(0x22)), phone: phoneIdentity)), .completed)
    }

    func testPhoneDoesNotRevealUntilTheHostAccepted() {
        var phone = newPhone()
        XCTAssertNil(phone.sas)
        // Nothing but pairAccept moves the phone, and it never reveals on its own.
        XCTAssertEqual(phone.receive(helloMessage(Data(repeating: 1, count: 16))), .none)
        XCTAssertNil(phone.sas)
        guard case .send(.pairReveal(let key, let identity)) = phone.receive(
            .pairAccept(publicKey: publicData(fixedPrivateKey(0x11)), host: host)) else {
            return XCTFail()
        }
        XCTAssertEqual(key, publicData(fixedPrivateKey(0x22)))
        XCTAssertEqual(identity, phoneIdentity)
        XCTAssertNotNil(phone.sas)
    }

    func testPhoneRejectsAnInvalidOrReflectedHostKeyAndASecondAccept() {
        var bad = newPhone()
        XCTAssertEqual(bad.receive(.pairAccept(publicKey: Data(repeating: 4, count: 65), host: host)), .failed)
        XCTAssertNil(bad.pairKey)
        var reflected = newPhone()
        XCTAssertEqual(reflected.receive(.pairAccept(publicKey: publicData(fixedPrivateKey(0x22)), host: host)), .failed)
        var twice = newPhone()
        _ = twice.receive(.pairAccept(publicKey: publicData(fixedPrivateKey(0x11)), host: host))
        XCTAssertEqual(twice.receive(.pairAccept(publicKey: publicData(fixedPrivateKey(0x33)), host: host)), .failed)
    }

    func testHostRejectsBadCommitmentSecondOfferAndInvalidReveal() {
        var shortCommit = newMac()
        XCTAssertEqual(shortCommit.receive(.pairOffer(commitment: Data(repeating: 1, count: 31))), .failed)
        var mac = newMac()
        let phone = newPhone()
        _ = mac.receive(phone.offer)
        XCTAssertEqual(mac.receive(phone.offer), .failed)
        var invalid = newMac()
        _ = invalid.receive(phone.offer)
        XCTAssertEqual(
            invalid.receive(.pairReveal(publicKey: Data(repeating: 4, count: 65), phone: phoneIdentity)), .failed)
        var other = newMac()
        XCTAssertEqual(other.receive(.sealed(Data())), .failed)
        var notSelected = newMac()
        XCTAssertEqual(notSelected.receive(.notSelected), .failed)
    }

    func testMITMGivesDifferentSASOnEachSide() throws {
        // Attacker answers the phone with its own key; the host got the real commitment/reveal, but the phone's key
        // in the phone's transcript is paired with the attacker's key.
        var phone = newPhone()
        var mac = newMac()
        guard case .send = mac.receive(phone.offer) else { return XCTFail() }
        _ = phone.receive(.pairAccept(publicKey: publicData(fixedPrivateKey(0x77)), host: host))
        XCTAssertEqual(
            mac.receive(.pairReveal(publicKey: publicData(fixedPrivateKey(0x22)), phone: phoneIdentity)), .completed)
        XCTAssertNotEqual(phone.sas, mac.sas)
    }

    // MARK: Identity checks

    private func overlong(_ count: Int = 33) -> String { String(repeating: "a", count: count) }

    func testEmptyOrOverlongPeerNameFailsPairing() {
        for name in ["", overlong()] {
            // The phone receives a pairAccept with a bad hostName.
            var phone = newPhone()
            let badHost = HostIdentity(id: host.id, name: name, platform: .mac)
            XCTAssertEqual(
                phone.receive(.pairAccept(publicKey: publicData(fixedPrivateKey(0x11)), host: badHost)), .failed, "hostName \(name.utf8.count)")
            XCTAssertNil(phone.pairKey)
            XCTAssertNil(phone.host)
            // The host receives a pairReveal with a bad phoneName.
            var mac = newMac()
            let honest = newPhone()
            _ = mac.receive(honest.offer)
            let badPhone = PhoneIdentity(id: phoneIdentity.id, name: name, platform: .ios)
            XCTAssertEqual(
                mac.receive(.pairReveal(publicKey: publicData(fixedPrivateKey(0x22)), phone: badPhone)), .failed, "phoneName \(name.utf8.count)")
            XCTAssertNil(mac.pairKey)
            XCTAssertNil(mac.phone)
        }
        // 32 bytes is still fine.
        var phone = newPhone()
        let fine = HostIdentity(id: host.id, name: overlong(32), platform: .linux)
        guard case .send = phone.receive(.pairAccept(publicKey: publicData(fixedPrivateKey(0x11)), host: fine)) else {
            return XCTFail("a 32-byte name is valid")
        }
    }

    func testWrongIdLengthFailsPairing() {
        for length in [0, 15, 17] {
            var phone = newPhone()
            let badHost = HostIdentity(id: Data(repeating: 1, count: length), name: "H", platform: .windows)
            XCTAssertEqual(
                phone.receive(.pairAccept(publicKey: publicData(fixedPrivateKey(0x11)), host: badHost)), .failed, "hostId \(length)")
            var mac = newMac()
            _ = mac.receive(newPhone().offer)
            let badPhone = PhoneIdentity(id: Data(repeating: 1, count: length), name: "P", platform: .android)
            XCTAssertEqual(
                mac.receive(.pairReveal(publicKey: publicData(fixedPrivateKey(0x22)), phone: badPhone)), .failed, "phoneId \(length)")
        }
    }

    func testEveryPlatformPairs() throws {
        for hostPlatform in [HostPlatform.mac, .windows, .linux] {
            for phonePlatform in [PhonePlatform.ios, .android] {
                var phone = newPhone(identity: PhoneIdentity(id: phoneIdentity.id, name: "P", platform: phonePlatform))
                var mac = newMac(identity: HostIdentity(id: host.id, name: "H", platform: hostPlatform))
                guard case .send(let accept) = mac.receive(phone.offer), case .send(let reveal) = phone.receive(accept) else {
                    return XCTFail("\(hostPlatform) \(phonePlatform)")
                }
                XCTAssertEqual(mac.receive(reveal), .completed)
                XCTAssertEqual(phone.sas, mac.sas)
            }
        }
    }
}
