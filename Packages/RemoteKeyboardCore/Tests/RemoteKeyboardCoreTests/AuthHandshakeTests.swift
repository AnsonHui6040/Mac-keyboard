import CryptoKit
import XCTest
@testable import RemoteKeyboardCore

final class AuthHandshakeTests: XCTestCase {
    private let pairKey = SymmetricKey(data: Data(repeating: 5, count: 32))
    private let otherKey = SymmetricKey(data: Data(repeating: 6, count: 32))
    private let hostNonce = Data(repeating: 1, count: 16)
    private let phoneNonce = Data(repeating: 2, count: 16)

    private func makeEvent(_ kind: EventKind = .text("A")) -> KeyboardEvent {
        KeyboardEvent(
            protocolVersion: KeyboardEvent.currentVersion, eventId: UUID(), sessionId: UUID(), seq: 1, focusEpoch: 3, kind: kind)
    }

    /// Runs hello → helloReply → auth with the given keys and returns the finished reducers.
    private func handshake(macKey: SymmetricKey?, phoneKey: SymmetricKey?)
        -> (mac: MacHandshake, phone: PhoneHandshake, macOut: MacHandshakeOutput, phoneOut: PhoneHandshakeOutput)
    {
        var mac = makeMac(macKey, nonce: hostNonce)
        var phone = makePhone(phoneKey, nonce: phoneNonce)
        let begun = mac.begin()
        guard case .send(let hello) = begun else { return (mac, phone, begun, .none) }
        guard case .send(let reply) = phone.receive(hello) else {
            return (mac, phone, .none, .failed)
        }
        let macOut = mac.receive(reply)
        guard case .authenticated(let auth, _) = macOut else { return (mac, phone, macOut, .none) }
        let phoneOut = phone.receive(auth)
        return (mac, phone, macOut, phoneOut)
    }

    func testHappyPathAuthenticatesBothSidesAndCarriesAnEvent() throws {
        var (mac, phone, macOut, phoneOut) = handshake(macKey: pairKey, phoneKey: pairKey)
        guard case .authenticated = macOut else { return XCTFail("\(macOut)") }
        XCTAssertEqual(phoneOut, .authenticated)
        XCTAssertTrue(phone.canSendEvents)
        XCTAssertTrue(mac.isAuthenticated)
        let event = makeEvent(.text("香港"))
        let message = try phone.sealEvent(event)
        guard case .sealed = message else { return XCTFail("must be sealed on the wire") }
        // Through the real codec, as the wire does.
        let wire = try PeripheralCodec.encode(message)
        XCTAssertEqual(mac.receive(try PeripheralCodec.decode(wire)), .event(event))
    }

    func testBeginSendsHelloWithTheMacNonce() {
        var mac = makeMac(pairKey, nonce: hostNonce)
        XCTAssertEqual(mac.begin(), .send(helloMessage(hostNonce)))
        XCTAssertFalse(mac.isAuthenticated)
    }

    func testWrongKeyProofRejected() {
        let result = handshake(macKey: pairKey, phoneKey: otherKey)
        XCTAssertEqual(result.macOut, .authFailed)
        XCTAssertFalse(result.mac.isAuthenticated)
        XCTAssertNil(result.mac.statusToSend(appName: "Notes"))
    }

    func testPhoneSendsNoEventBeforeMacAuth() throws {
        var mac = makeMac(pairKey, nonce: hostNonce)
        var phone = makePhone(pairKey, nonce: phoneNonce)
        XCTAssertFalse(phone.canSendEvents)
        XCTAssertThrowsError(try phone.sealEvent(makeEvent())) { XCTAssertEqual($0 as? HandshakeError, .notAuthenticated) }
        guard case .send(let hello) = mac.begin(), case .send(let reply) = phone.receive(hello) else { return XCTFail("hello") }
        // The phone has answered but the Mac has not proven itself yet.
        XCTAssertFalse(phone.canSendEvents)
        XCTAssertThrowsError(try phone.sealEvent(makeEvent())) { XCTAssertEqual($0 as? HandshakeError, .notAuthenticated) }
        guard case .authenticated(let auth, _) = mac.receive(reply) else { return XCTFail("mac") }
        XCTAssertEqual(phone.receive(auth), .authenticated)
        XCTAssertTrue(phone.canSendEvents)
    }

    func testPhoneRejectsAMacThatDoesNotKnowTheKey() throws {
        // A fake Mac that never saw the pair key: its auth proof is computed with another key.
        var phone = makePhone(pairKey, nonce: phoneNonce)
        _ = phone.receive(helloMessage(hostNonce))
        let forged = Pairing.hostProof(key: otherKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
        XCTAssertEqual(phone.receive(.auth(proof: forged)), .failed)
        XCTAssertFalse(phone.canSendEvents)
        XCTAssertThrowsError(try phone.sealEvent(makeEvent()))
    }

    func testPhoneRejectsAPhoneProofReflectedAsMacAuth() {
        var phone = makePhone(pairKey, nonce: phoneNonce)
        _ = phone.receive(helloMessage(hostNonce))
        let reflected = Pairing.phoneProof(key: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
        XCTAssertEqual(phone.receive(.auth(proof: reflected)), .failed)
        XCTAssertFalse(phone.canSendEvents)
    }

    func testPhoneIgnoresAuthThatArrivesWithoutAHello() {
        var phone = makePhone(pairKey, nonce: phoneNonce)
        XCTAssertEqual(phone.receive(.auth(proof: Data(repeating: 0, count: 32))), .failed)
        XCTAssertFalse(phone.canSendEvents)
    }

    func testPhoneFailureIsSticky() {
        var phone = makePhone(pairKey, nonce: phoneNonce)
        _ = phone.receive(helloMessage(hostNonce))
        XCTAssertEqual(phone.receive(.auth(proof: Data(repeating: 0, count: 32))), .failed)
        // A correct proof arriving afterwards must not resurrect the link.
        let good = Pairing.hostProof(key: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
        XCTAssertNotEqual(phone.receive(.auth(proof: good)), .authenticated)
        XCTAssertFalse(phone.canSendEvents)
    }

    func testPhoneTreatsAuthFailedAsFailure() {
        var phone = makePhone(pairKey, nonce: phoneNonce)
        _ = phone.receive(helloMessage(hostNonce))
        XCTAssertEqual(phone.receive(.authFailed), .failed)
        XCTAssertFalse(phone.canSendEvents)
    }

    func testPhoneRejectsBadHelloNonceLength() {
        for length in [0, 15, 17] {
            var phone = makePhone(pairKey, nonce: phoneNonce)
            XCTAssertEqual(phone.receive(helloMessage(Data(repeating: 1, count: length))), .failed, "length \(length)")
        }
    }

    func testPhoneWithoutACurrentHostNeverAuthenticatesAndAnswersNotSelected() {
        var phone = makePhone(nil, nonce: phoneNonce)
        XCTAssertFalse(phone.canSendEvents)
        XCTAssertEqual(phone.receive(helloMessage(hostNonce)), .send(.notSelected))
        XCTAssertFalse(phone.canSendEvents)
        XCTAssertThrowsError(try phone.sealEvent(makeEvent()))
    }

    func testPhoneWithAMalformedNonceNeverAuthenticates() {
        var phone = makePhone(pairKey, nonce: Data(repeating: 2, count: 8))
        XCTAssertEqual(phone.receive(helloMessage(hostNonce)), .failed)
        XCTAssertFalse(phone.canSendEvents)
    }

    func testPhoneDropsPlainStatusBeforeAuthAndDeliversSealedAfter() throws {
        var phone = makePhone(pairKey, nonce: phoneNonce)
        let status = ControlMessage.status(ReceiverStatus(ready: true, appName: "Notes", focusEpoch: 1))
        let ack = ControlMessage.ack(Ack(eventId: UUID(), result: .posted))
        XCTAssertEqual(phone.receive(status), .none)
        _ = phone.receive(helloMessage(hostNonce))
        XCTAssertEqual(phone.receive(ack), .none)
        var (mac, phone2, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        XCTAssertEqual(phone2.receive(try mac.sealControl(status)), .deliver(status))
        XCTAssertEqual(phone2.receive(try mac.sealControl(ack)), .deliver(ack))
        XCTAssertTrue(phone2.canSendEvents)
    }

    func testPlainStatusAfterAuthFailsPhoneSession() {
        var (_, phone, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        XCTAssertTrue(phone.canSendEvents)
        let status = ControlMessage.status(ReceiverStatus(ready: true, appName: "Notes", focusEpoch: 1))
        XCTAssertEqual(phone.receive(status), .failed)
        XCTAssertFalse(phone.canSendEvents)
        // Sticky: a good sealed message afterwards changes nothing.
        XCTAssertThrowsError(try phone.sealEvent(makeEvent()))
        var (_, phone2, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        XCTAssertEqual(phone2.receive(.ack(Ack(eventId: UUID(), result: .posted))), .failed)
        XCTAssertFalse(phone2.canSendEvents)
    }

    func testPhoneRejectsSealedControlBeforeAuthAndBadInnerOrTamper() throws {
        var early = makePhone(pairKey, nonce: phoneNonce)
        _ = early.receive(helloMessage(hostNonce))
        let macToPhone = SessionCrypto(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, direction: .macToPhone)
        let status = ControlMessage.status(ReceiverStatus(ready: true, appName: "Notes", focusEpoch: 1))
        let sealedStatus = ControlMessage.sealed(try macToPhone.seal(ControlCodec.encode(status)))
        XCTAssertEqual(early.receive(sealedStatus), .failed)

        // Only ack and status may live inside; a sealed authFailed or nested sealed is a violation.
        for inner in [ControlMessage.authFailed, helloMessage(hostNonce), .sealed(Data([1, 2, 3]))] {
            var (_, phone, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
            XCTAssertEqual(phone.receive(.sealed(try macToPhone.seal(ControlCodec.encode(inner)))), .failed)
            XCTAssertFalse(phone.canSendEvents)
        }
        // Tampered and wrong-direction ciphertext.
        var (_, phone3, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        guard case .sealed(var bytes) = sealedStatus else { return XCTFail() }
        bytes[bytes.startIndex + 15] ^= 1
        XCTAssertEqual(phone3.receive(.sealed(bytes)), .failed)
        var (_, phone4, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        let p2m = SessionCrypto(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, direction: .phoneToMac)
        XCTAssertEqual(phone4.receive(.sealed(try p2m.seal(ControlCodec.encode(status)))), .failed)
    }

    func testPhoneAcceptsAuthFailedAfterAuthAsFailure() {
        var (_, phone, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        XCTAssertEqual(phone.receive(.authFailed), .failed)
        XCTAssertFalse(phone.canSendEvents)
    }

    func testAppNameNeverInPlainControlBytes() throws {
        let (mac, _, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        let name = "SecretNotesApp"
        let appName = try XCTUnwrap(mac.statusToSend(appName: name))
        let status = ControlMessage.status(ReceiverStatus(ready: true, appName: appName, focusEpoch: 2))
        let sealed = try mac.sealControl(status)
        let wire = try ControlCodec.encode(sealed)
        XCTAssertNil(wire.range(of: Data(name.utf8)))
        XCTAssertNil(String(decoding: wire, as: UTF8.self).range(of: name))
        // The sealed text is not even in the base64 of the plain status.
        XCTAssertNotNil(try ControlCodec.encode(status).range(of: Data(name.utf8)))
        guard case .sealed = sealed else { return XCTFail("status must leave the Mac sealed") }
    }

    func testMacSealControlNeedsAuthAndOnlyAckOrStatus() throws {
        var early = makeMac(pairKey, nonce: hostNonce)
        _ = early.begin()
        let status = ControlMessage.status(ReceiverStatus(ready: false, appName: nil, focusEpoch: 0))
        XCTAssertThrowsError(try early.sealControl(status)) { XCTAssertEqual($0 as? HandshakeError, .notAuthenticated) }
        let (mac, _, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        for bad in [ControlMessage.authFailed, helloMessage(hostNonce), .auth(proof: Data(repeating: 0, count: 32)),
                    .pairAccept(publicKey: Data(), host: Fixture.hostIdentity), .sealed(Data())] {
            XCTAssertThrowsError(try mac.sealControl(bad)) { XCTAssertEqual($0 as? HandshakeError, .invalidControlMessage) }
        }
    }

    func testByeIsAllowedInsideSealedControlAndDelivered() throws {
        var (mac, phone, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        let sealed = try mac.sealControl(.bye)
        guard case .sealed = sealed else { return XCTFail("bye must leave the Mac sealed") }
        XCTAssertEqual(phone.receive(sealed), .deliver(.bye))
        XCTAssertTrue(phone.canSendEvents, "a goodbye is delivered, not a violation; the adapter does the reset")
        // Nothing readable on the wire.
        let wire = try ControlCodec.encode(sealed)
        XCTAssertNil(String(decoding: wire, as: UTF8.self).range(of: "bye"))
        XCTAssertLessThan(wire.count, 512)
    }

    func testPlainByeIsNeverAccepted() throws {
        // Before auth it is dropped like any other post-auth message; after auth a plain one is a violation.
        var early = makePhone(pairKey, nonce: phoneNonce)
        XCTAssertEqual(early.receive(.bye), .none)
        _ = early.receive(helloMessage(hostNonce))
        XCTAssertEqual(early.receive(.bye), .none)
        var (_, phone, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        XCTAssertEqual(phone.receive(.bye), .failed)
        XCTAssertFalse(phone.canSendEvents)
    }

    func testSealedByeBeforeAuthFailsThePhone() throws {
        var early = makePhone(pairKey, nonce: phoneNonce)
        _ = early.receive(helloMessage(hostNonce))
        let macToPhone = SessionCrypto(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, direction: .macToPhone)
        XCTAssertEqual(early.receive(.sealed(try macToPhone.seal(ControlCodec.encode(.bye)))), .failed)
    }

    func testMacCannotSealByeBeforeAuth() {
        var early = makeMac(pairKey, nonce: hostNonce)
        _ = early.begin()
        XCTAssertThrowsError(try early.sealControl(.bye)) { XCTAssertEqual($0 as? HandshakeError, .notAuthenticated) }
    }

    func testSealControlRejectsOtherInnerMessagesStill() throws {
        let (mac, _, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        for bad in [ControlMessage.authFailed, helloMessage(hostNonce), .auth(proof: Data(repeating: 0, count: 32)),
                    .pairAccept(publicKey: Data(), host: Fixture.hostIdentity), .sealed(Data())] {
            XCTAssertThrowsError(try mac.sealControl(bad)) { XCTAssertEqual($0 as? HandshakeError, .invalidControlMessage) }
        }
        for good in [ControlMessage.ack(Ack(eventId: UUID(), result: .pong)),
                     .status(ReceiverStatus(ready: true, appName: nil, focusEpoch: 1)), .bye] {
            XCTAssertNoThrow(try mac.sealControl(good))
        }
        // The phone still fails on a sealed inner message that is not ack, status or bye.
        let macToPhone = SessionCrypto(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, direction: .macToPhone)
        for inner in [ControlMessage.authFailed, helloMessage(hostNonce), .sealed(Data([1, 2, 3]))] {
            var (_, phone, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
            XCTAssertEqual(phone.receive(.sealed(try macToPhone.seal(ControlCodec.encode(inner)))), .failed)
        }
    }

    func testSealedStatusWithLongAppNameStaysUnderOneControlWrite() throws {
        let (mac, _, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        let status = ControlMessage.status(ReceiverStatus(ready: true, appName: String(repeating: "香", count: 60), focusEpoch: UInt64.max))
        XCTAssertLessThan(try ControlCodec.encode(mac.sealControl(status)).count, 512)
        let untrusted = ControlMessage.status(ReceiverStatus(
            ready: false, appName: String(repeating: "香", count: 60), focusEpoch: UInt64.max, trusted: false))
        XCTAssertLessThan(try ControlCodec.encode(mac.sealControl(untrusted)).count, 512)
    }

    func testRepeatedHelloFailsThePhoneSession() {
        var waiting = makePhone(pairKey, nonce: phoneNonce)
        _ = waiting.receive(helloMessage(hostNonce))
        XCTAssertEqual(waiting.receive(helloMessage(hostNonce)), .failed)
        let good = Pairing.hostProof(key: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
        XCTAssertNotEqual(waiting.receive(.auth(proof: good)), .authenticated)
        XCTAssertFalse(waiting.canSendEvents)
        var (_, authed, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        XCTAssertEqual(authed.receive(helloMessage(Data(repeating: 9, count: 16))), .failed)
        XCTAssertFalse(authed.canSendEvents)
    }

    func testBeginOnAFailedMacDoesNotReportTheFailureAgain() {
        var mac = makeMac(pairKey, nonce: hostNonce)
        _ = mac.begin()
        XCTAssertEqual(mac.receive(.event(makeEvent())), .authFailed)
        XCTAssertEqual(mac.begin(), .none)
        // A Mac that failed at init (bad own nonce) reports it exactly once, from begin().
        var broken = makeMac(pairKey, nonce: Data(count: 3))
        XCTAssertEqual(broken.begin(), .authFailed)
        XCTAssertEqual(broken.begin(), .none)
    }

    func testMacWritesNoAppNameBeforePhoneVerified() {
        var mac = makeMac(pairKey, nonce: hostNonce)
        XCTAssertNil(mac.statusToSend(appName: "Notes"))
        _ = mac.begin()
        XCTAssertNil(mac.statusToSend(appName: "Notes"))
        let phoneProof = Pairing.phoneProof(key: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
        guard case .authenticated = mac.receive(.helloReply(phoneNonce: phoneNonce, proof: phoneProof)) else { return XCTFail() }
        XCTAssertEqual(mac.statusToSend(appName: "Notes"), "Notes")
        XCTAssertNil(mac.statusToSend(appName: nil))
    }

    func testMacAuthReplyIsAValidMacProof() {
        var mac = makeMac(pairKey, nonce: hostNonce)
        _ = mac.begin()
        let proof = Pairing.phoneProof(key: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
        let expected = Pairing.hostProof(key: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
        XCTAssertEqual(
            mac.receive(.helloReply(phoneNonce: phoneNonce, proof: proof)),
            .authenticated(reply: .auth(proof: expected), phoneId: Fixture.phoneId))
    }

    func testRevokedPairingCannotAuthenticate() {
        // The Mac deleted its pairing (no phones left); the same iPhone still holds the old key. A host with no key fails
        // closed before it writes anything.
        let result = handshake(macKey: nil, phoneKey: pairKey)
        XCTAssertEqual(result.macOut, .authFailed)
        XCTAssertFalse(result.mac.isAuthenticated)
        XCTAssertNil(result.mac.statusToSend(appName: "Notes"))
        XCTAssertFalse(result.phone.canSendEvents)
    }

    func testMacRejectsHelloReplyWithBadLengths() {
        let proof = Pairing.phoneProof(key: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
        let cases: [(Data, Data)] = [
            (Data(repeating: 2, count: 15), proof), (Data(repeating: 2, count: 17), proof), (Data(), proof),
            (phoneNonce, proof.dropLast()), (phoneNonce, proof + [0]), (phoneNonce, Data())
        ]
        for (nonce, bad) in cases {
            var mac = makeMac(pairKey, nonce: hostNonce)
            _ = mac.begin()
            XCTAssertEqual(mac.receive(.helloReply(phoneNonce: nonce, proof: bad)), .authFailed)
            XCTAssertFalse(mac.isAuthenticated)
        }
    }

    func testMacRejectsHelloReplyBeforeItSentHello() {
        var mac = makeMac(pairKey, nonce: hostNonce)
        let proof = Pairing.phoneProof(key: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
        XCTAssertEqual(mac.receive(.helloReply(phoneNonce: phoneNonce, proof: proof)), .authFailed)
    }

    func testMacRejectsAHelloReplyForAnotherSession() {
        // The proof was computed over an old hostNonce, as a recorded reply would be.
        var mac = makeMac(pairKey, nonce: hostNonce)
        _ = mac.begin()
        let stale = Pairing.phoneProof(key: pairKey, hostNonce: Data(repeating: 7, count: 16), phoneNonce: phoneNonce)
        XCTAssertEqual(mac.receive(.helloReply(phoneNonce: phoneNonce, proof: stale)), .authFailed)
    }

    func testMacWithABadOwnNonceFailsClosed() {
        var mac = makeMac(pairKey, nonce: Data(repeating: 1, count: 4))
        XCTAssertEqual(mac.begin(), .authFailed)
    }

    func testPlaintextEventIsAProtocolViolationBeforeAndAfterAuth() {
        let plain = PeripheralMessage.event(makeEvent())
        var early = makeMac(pairKey, nonce: hostNonce)
        _ = early.begin()
        XCTAssertEqual(early.receive(plain), .authFailed)
        var authed = handshake(macKey: pairKey, phoneKey: pairKey).mac
        XCTAssertEqual(authed.receive(plain), .authFailed)
    }

    func testSealedBeforeAuthenticationIsAProtocolViolation() throws {
        var mac = makeMac(pairKey, nonce: hostNonce)
        _ = mac.begin()
        let session = SessionCrypto(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, direction: .phoneToMac)
        let sealed = try session.seal(PeripheralCodec.encode(.event(makeEvent())))
        XCTAssertEqual(mac.receive(.sealed(sealed)), .authFailed)
    }

    func testPairingMessagesAreForwardedOnThePairingRouteOnly() {
        let phoneKey = publicData(fixedPrivateKey(0x22))
        let commitment = Pairing.commitment(phonePublic: phoneKey)
        let offer = PeripheralMessage.pairOffer(commitment: commitment)
        let reveal = PeripheralMessage.pairReveal(publicKey: phoneKey, phone: Fixture.phoneIdentity)
        var mac = makeMac(nil, nonce: hostNonce, route: .pairing)
        XCTAssertEqual(mac.begin(), .none, "a connection found through the pairing UUID never gets a hello")
        XCTAssertEqual(mac.receive(offer), .pairOffer(commitment: commitment))
        XCTAssertEqual(mac.receive(reveal), .pairReveal(publicKey: phoneKey, phone: Fixture.phoneIdentity))
        XCTAssertFalse(mac.isAuthenticated)
        // A connection found through the selected UUID only walks the handshake: pairing messages fail it, before and after auth.
        var early = makeMac(pairKey, nonce: hostNonce)
        _ = early.begin()
        XCTAssertEqual(early.receive(offer), .authFailed)
        var early2 = makeMac(pairKey, nonce: hostNonce)
        _ = early2.begin()
        XCTAssertEqual(early2.receive(reveal), .authFailed)
        var authed = handshake(macKey: pairKey, phoneKey: pairKey).mac
        XCTAssertEqual(authed.receive(offer), .authFailed)
        var authed2 = handshake(macKey: pairKey, phoneKey: pairKey).mac
        XCTAssertEqual(authed2.receive(reveal), .authFailed)
    }

    func testPairingRouteRejectsTheHandshakeMessages() throws {
        let proof = Pairing.phoneProof(key: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
        var a = makeMac(pairKey, nonce: hostNonce, route: .pairing)
        XCTAssertEqual(a.receive(.helloReply(phoneNonce: phoneNonce, proof: proof)), .authFailed)
        var b = makeMac(pairKey, nonce: hostNonce, route: .pairing)
        let session = SessionCrypto(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, direction: .phoneToMac)
        XCTAssertEqual(b.receive(.sealed(try session.seal(Data("x".utf8)))), .authFailed)
        var c = makeMac(pairKey, nonce: hostNonce, route: .pairing)
        XCTAssertEqual(c.receive(.notSelected), .authFailed)
    }

    func testMalformedPairingPayloadsFailAuth() {
        var mac = makeMac(nil, nonce: hostNonce, route: .pairing)
        _ = mac.begin()
        XCTAssertEqual(mac.receive(.pairOffer(commitment: Data(repeating: 4, count: 31))), .authFailed)
        var mac2 = makeMac(nil, nonce: hostNonce, route: .pairing)
        XCTAssertEqual(
            mac2.receive(.pairReveal(publicKey: Data(repeating: 4, count: 65), phone: Fixture.phoneIdentity)), .authFailed)
        var mac3 = makeMac(nil, nonce: hostNonce, route: .pairing)
        XCTAssertEqual(mac3.receive(.pairReveal(publicKey: Data(), phone: Fixture.phoneIdentity)), .authFailed)
    }

    func testTamperedSealedAfterAuthFailsAuth() throws {
        var (mac, phone, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        guard case .sealed(var data) = try phone.sealEvent(makeEvent()) else { return XCTFail() }
        data[data.startIndex + 20] ^= 0x01
        XCTAssertEqual(mac.receive(.sealed(data)), .authFailed)
        XCTAssertFalse(mac.isAuthenticated)
        XCTAssertNil(mac.statusToSend(appName: "Notes"))
    }

    func testGarbageSealedAfterAuthFailsAuth() {
        var mac = handshake(macKey: pairKey, phoneKey: pairKey).mac
        XCTAssertEqual(mac.receive(.sealed(Data())), .authFailed)
    }

    func testSealedGoodCryptoButMalformedInnerPayloadIsMalformedNotAuthFailure() throws {
        var mac = handshake(macKey: pairKey, phoneKey: pairKey).mac
        let session = SessionCrypto(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, direction: .phoneToMac)
        let sealed = try session.seal(Data("not json".utf8))
        XCTAssertEqual(mac.receive(.sealed(sealed)), .malformedPayload)
        XCTAssertTrue(mac.isAuthenticated)
    }

    func testSealedNonEventInnerMessageFailsAuth() throws {
        var mac = handshake(macKey: pairKey, phoneKey: pairKey).mac
        let session = SessionCrypto(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, direction: .phoneToMac)
        let inner = try PeripheralCodec.encode(.pairReveal(publicKey: publicData(fixedPrivateKey(0x22)), phone: Fixture.phoneIdentity))
        XCTAssertEqual(mac.receive(.sealed(try session.seal(inner))), .authFailed)
    }

    func testMacFailureIsStickyAndReportedOnce() {
        var mac = makeMac(pairKey, nonce: hostNonce)
        _ = mac.begin()
        XCTAssertEqual(mac.receive(.event(makeEvent())), .authFailed)
        let good = Pairing.phoneProof(key: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
        XCTAssertEqual(mac.receive(.helloReply(phoneNonce: phoneNonce, proof: good)), .none)
        XCTAssertFalse(mac.isAuthenticated)
        XCTAssertNil(mac.statusToSend(appName: "Notes"))
    }

    func testReplayedSealedFromAnEarlierHandshakeFailsInANewOne() throws {
        let first = handshake(macKey: pairKey, phoneKey: pairKey)
        guard case .sealed(let recorded) = try first.phone.sealEvent(makeEvent()) else { return XCTFail() }
        // New session: fresh nonces on both sides.
        var mac = makeMac(pairKey, nonce: Data(repeating: 0x41, count: 16))
        var phone = makePhone(pairKey, nonce: Data(repeating: 0x42, count: 16))
        guard case .send(let hello) = mac.begin(), case .send(let reply) = phone.receive(hello),
              case .authenticated = mac.receive(reply) else { return XCTFail("second handshake") }
        XCTAssertEqual(mac.receive(.sealed(recorded)), .authFailed)
    }

    // MARK: Channel set

    func testChannelSetNilBeforeAuthenticated() {
        var mac = makeMac(pairKey, nonce: hostNonce)
        var phone = makePhone(pairKey, nonce: phoneNonce)
        XCTAssertNil(mac.takeChannelSet())
        XCTAssertNil(phone.takeChannelSet())
        guard case .send(let hello) = mac.begin(), case .send(let reply) = phone.receive(hello) else { return XCTFail("hello") }
        // The phone answered, but neither side is authenticated yet.
        XCTAssertNil(mac.takeChannelSet())
        XCTAssertNil(phone.takeChannelSet())
        guard case .authenticated(let auth, _) = mac.receive(reply) else { return XCTFail("mac") }
        XCTAssertNil(phone.takeChannelSet(), "the phone is authenticated only when the Mac's proof verified")
        XCTAssertNotNil(mac.takeChannelSet())
        XCTAssertEqual(phone.receive(auth), .authenticated)
        XCTAssertNotNil(phone.takeChannelSet())
    }

    func testChannelSetNilAfterFailure() {
        var (mac, phone, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        XCTAssertEqual(mac.receive(.event(makeEvent())), .authFailed)
        XCTAssertNil(mac.takeChannelSet())
        XCTAssertEqual(phone.receive(.authFailed), .failed)
        XCTAssertNil(phone.takeChannelSet())
    }

    func testChannelSetsInteroperateBothSides() throws {
        var (mac, phone, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        let macSet = try XCTUnwrap(mac.takeChannelSet())
        let phoneSet = try XCTUnwrap(phone.takeChannelSet())
        let plain = Data(repeating: 0x42, count: 16)
        // iPhone to Mac.
        let packet = try phoneSet.sealer(.pointer).seal(plain)
        XCTAssertEqual(try macSet.opener(.pointer).open(packet).get(), plain)
        #if DEBUG
        XCTAssertEqual(try macSet.opener(.measureP2M).open(try phoneSet.sealer(.measureP2M).seal(plain)).get(), plain)
        // Mac to iPhone.
        let reply = Data(repeating: 0x42, count: 24)
        XCTAssertEqual(try phoneSet.opener(.measureM2P).open(try macSet.sealer(.measureM2P).seal(reply)).get(), reply)
        #endif
    }

    func testChannelSetsOfAnotherHandshakeDoNotOpenEachOther() throws {
        var first = handshake(macKey: pairKey, phoneKey: pairKey).phone
        var second = makePhone(pairKey, nonce: Data(repeating: 0x42, count: 16))
        var secondMac = makeMac(pairKey, nonce: Data(repeating: 0x41, count: 16))
        guard case .send(let hello) = secondMac.begin(), case .send(let reply) = second.receive(hello),
              case .authenticated(let auth, _) = secondMac.receive(reply), second.receive(auth) == .authenticated
        else { return XCTFail("second handshake") }
        let recorded = try XCTUnwrap(first.takeChannelSet()).sealer(.pointer).seal(Data(repeating: 1, count: 16))
        let macSet = try XCTUnwrap(secondMac.takeChannelSet())
        XCTAssertEqual(macSet.opener(.pointer).open(recorded), .failure(.authFailed))
    }

    // MARK: Protocol v4: hello routing and notSelected

    private let otherHostId = Data(repeating: 0xEE, count: 16)

    func testHelloForSelectedHostReplies() throws {
        var phone = makePhone(pairKey, nonce: phoneNonce)
        let proof = Pairing.phoneProof(key: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
        XCTAssertEqual(phone.receive(helloMessage(hostNonce)), .send(.helloReply(phoneNonce: phoneNonce, proof: proof)))
    }

    func testHelloForOtherHostRepliesNotSelected() {
        // Not the current host: a notSelected, whether or not the iPhone ever paired with that host.
        var phone = makePhone(pairKey, nonce: phoneNonce)
        XCTAssertEqual(phone.receive(.hello(hostId: otherHostId, hostNonce: hostNonce)), .send(.notSelected))
        XCTAssertEqual(phone.progress, .inProgress, "no state is kept")
        // The right host can still handshake afterwards on the same reducer.
        guard case .send(.helloReply) = phone.receive(helloMessage(hostNonce)) else { return XCTFail("matching hello must be answered") }
        // No current host at all.
        var none = makePhone(nil, nonce: phoneNonce)
        XCTAssertEqual(none.receive(.hello(hostId: otherHostId, hostNonce: hostNonce)), .send(.notSelected))
        XCTAssertEqual(none.receive(helloMessage(hostNonce)), .send(.notSelected))
        XCTAssertFalse(none.canSendEvents)
    }

    func testNotSelectedBodyIsIndependentOfWhetherTheHostWasEverPaired() {
        var a = makePhone(pairKey, nonce: phoneNonce)
        var b = makePhone(pairKey, nonce: phoneNonce)
        let pairedBefore = a.receive(.hello(hostId: Data(repeating: 0x01, count: 16), hostNonce: hostNonce))
        let neverPaired = b.receive(.hello(hostId: Data(repeating: 0x02, count: 16), hostNonce: hostNonce))
        XCTAssertEqual(pairedBefore, neverPaired)
    }

    func testHelloWithBadHostIdLengthFails() {
        for length in [0, 15, 17] {
            var phone = makePhone(pairKey, nonce: phoneNonce)
            XCTAssertEqual(
                phone.receive(.hello(hostId: Data(repeating: 0, count: length), hostNonce: hostNonce)), .failed, "hostId \(length)")
            XCTAssertEqual(phone.progress, .failed)
        }
        for length in [0, 15, 17] {
            var phone = makePhone(pairKey, nonce: phoneNonce)
            XCTAssertEqual(
                phone.receive(.hello(hostId: Fixture.hostId, hostNonce: Data(repeating: 0, count: length))), .failed, "hostNonce \(length)")
        }
        // Malformed wins over "not the current host".
        var none = makePhone(nil, nonce: phoneNonce)
        XCTAssertEqual(none.receive(.hello(hostId: Data(repeating: 0, count: 15), hostNonce: hostNonce)), .failed)
    }

    func testHostTreatsNotSelectedAsBackoff() {
        var mac = makeMac(pairKey, nonce: hostNonce)
        _ = mac.begin()
        XCTAssertEqual(mac.receive(.notSelected), .notSelected)
        XCTAssertFalse(mac.isAuthenticated)
        // The reducer is done: nothing more comes out of it, in particular no authFailed to write.
        XCTAssertEqual(mac.receive(.event(makeEvent())), .none)
        XCTAssertEqual(mac.begin(), .none)
    }

    func testNotSelectedAfterAuthenticationIsAViolation() {
        var mac = handshake(macKey: pairKey, phoneKey: pairKey).mac
        XCTAssertEqual(mac.receive(.notSelected), .authFailed)
    }

    // MARK: Protocol v4: key per phone

    private func phoneEntry(_ n: UInt8) -> PairedPhone {
        PairedPhone(
            identity: PhoneIdentity(id: Data(repeating: n, count: 16), name: "phone\(n)", platform: n.isMultiple(of: 2) ? .android : .ios),
            pairKey: SymmetricKey(data: Data(repeating: n &+ 100, count: 32)))
    }

    private func runAgainstEight(target index: Int) throws {
        let phones = (1...8).map { phoneEntry(UInt8($0)) }
        var mac = MacHandshake(hostId: Fixture.hostId, phones: phones, hostNonce: hostNonce)
        var phone = PhoneHandshake(selected: (hostId: Fixture.hostId, pairKey: phones[index].pairKey), phoneNonce: phoneNonce)
        guard case .send(let hello) = mac.begin(), case .send(let reply) = phone.receive(hello) else { return XCTFail("hello") }
        guard case .authenticated(let auth, let phoneId) = mac.receive(reply) else { return XCTFail("phone \(index) must be found") }
        XCTAssertEqual(phoneId, phones[index].identity.id)
        XCTAssertEqual(phone.receive(auth), .authenticated)
        // The session uses that phone's key: an event travels both ways.
        let event = makeEvent(.text("香港"))
        XCTAssertEqual(mac.receive(try phone.sealEvent(event)), .event(event))
        XCTAssertEqual(phone.receive(try mac.sealControl(.bye)), .deliver(.bye))
    }

    func testHostFindsKeyAmongSeveralPhones() throws {
        try runAgainstEight(target: 0)
        try runAgainstEight(target: 7)
        try runAgainstEight(target: 3)
    }

    func testUnknownPhoneFailsAfterAllKeys() {
        let phones = (1...8).map { phoneEntry(UInt8($0)) }
        var mac = MacHandshake(hostId: Fixture.hostId, phones: phones, hostNonce: hostNonce)
        var stranger = PhoneHandshake(
            selected: (hostId: Fixture.hostId, pairKey: SymmetricKey(data: Data(repeating: 0x55, count: 32))), phoneNonce: phoneNonce)
        guard case .send(let hello) = mac.begin(), case .send(let reply) = stranger.receive(hello) else { return XCTFail("hello") }
        XCTAssertEqual(mac.receive(reply), .authFailed)
        XCTAssertFalse(mac.isAuthenticated)
        XCTAssertNil(mac.takeChannelSet())
        XCTAssertNil(mac.statusToSend(appName: "Notes"))
    }

    func testNoPhonesFails() {
        // Fails closed before it writes a hello (docs/protocol/v4.md §6.2), and a helloReply could not succeed either.
        var mac = MacHandshake(hostId: Fixture.hostId, phones: [], hostNonce: hostNonce)
        XCTAssertEqual(mac.begin(), .authFailed)
        XCTAssertEqual(mac.begin(), .none)
        var other = MacHandshake(hostId: Fixture.hostId, phones: [], hostNonce: hostNonce)
        let proof = Pairing.phoneProof(key: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
        XCTAssertEqual(other.receive(.helloReply(phoneNonce: phoneNonce, proof: proof)), .authFailed)
    }

    func testTheFirstMatchingPhoneWinsWhenTwoShareAKey() {
        // Not expected in practice (each pairing derives its own key), but the order of the list decides.
        let shared = SymmetricKey(data: Data(repeating: 0x33, count: 32))
        let first = PairedPhone(identity: PhoneIdentity(id: Data(repeating: 1, count: 16), name: "a", platform: .ios), pairKey: shared)
        let second = PairedPhone(identity: PhoneIdentity(id: Data(repeating: 2, count: 16), name: "b", platform: .ios), pairKey: shared)
        var mac = MacHandshake(hostId: Fixture.hostId, phones: [first, second], hostNonce: hostNonce)
        _ = mac.begin()
        let proof = Pairing.phoneProof(key: shared, hostNonce: hostNonce, phoneNonce: phoneNonce)
        guard case .authenticated(_, let phoneId) = mac.receive(.helloReply(phoneNonce: phoneNonce, proof: proof)) else { return XCTFail() }
        XCTAssertEqual(phoneId, first.identity.id)
    }

    func testHandshakeWithABadHostIdFailsClosed() {
        var mac = MacHandshake(
            hostId: Data(repeating: 1, count: 15), phones: [phoneEntry(1)], hostNonce: hostNonce)
        XCTAssertEqual(mac.begin(), .authFailed)
    }
}
