import CryptoKit
import XCTest
@testable import RemoteKeyboardCore

final class AuthHandshakeTests: XCTestCase {
    private let pairKey = SymmetricKey(data: Data(repeating: 5, count: 32))
    private let otherKey = SymmetricKey(data: Data(repeating: 6, count: 32))
    private let macNonce = Data(repeating: 1, count: 16)
    private let phoneNonce = Data(repeating: 2, count: 16)

    private func makeEvent(_ kind: EventKind = .text("A")) -> KeyboardEvent {
        KeyboardEvent(
            protocolVersion: KeyboardEvent.currentVersion, eventId: UUID(), sessionId: UUID(), seq: 1, focusEpoch: 3, kind: kind)
    }

    /// Runs hello → helloReply → auth with the given keys and returns the finished reducers.
    private func handshake(macKey: SymmetricKey?, phoneKey: SymmetricKey?)
        -> (mac: MacHandshake, phone: PhoneHandshake, macOut: MacHandshakeOutput, phoneOut: PhoneHandshakeOutput)
    {
        var mac = MacHandshake(pairKey: macKey, macNonce: macNonce)
        var phone = PhoneHandshake(pairKey: phoneKey, phoneNonce: phoneNonce)
        guard case .send(let hello) = mac.begin() else { fatalError("begin must send hello") }
        guard case .send(let reply) = phone.receive(hello) else {
            return (mac, phone, .none, .failed)
        }
        let macOut = mac.receive(reply)
        guard case .authenticated(let auth) = macOut else { return (mac, phone, macOut, .none) }
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
        var mac = MacHandshake(pairKey: pairKey, macNonce: macNonce)
        XCTAssertEqual(mac.begin(), .send(.hello(macNonce: macNonce)))
        XCTAssertFalse(mac.isAuthenticated)
    }

    func testWrongKeyProofRejected() {
        let result = handshake(macKey: pairKey, phoneKey: otherKey)
        XCTAssertEqual(result.macOut, .authFailed)
        XCTAssertFalse(result.mac.isAuthenticated)
        XCTAssertNil(result.mac.statusToSend(appName: "Notes"))
    }

    func testPhoneSendsNoEventBeforeMacAuth() throws {
        var mac = MacHandshake(pairKey: pairKey, macNonce: macNonce)
        var phone = PhoneHandshake(pairKey: pairKey, phoneNonce: phoneNonce)
        XCTAssertFalse(phone.canSendEvents)
        XCTAssertThrowsError(try phone.sealEvent(makeEvent())) { XCTAssertEqual($0 as? HandshakeError, .notAuthenticated) }
        guard case .send(let hello) = mac.begin(), case .send(let reply) = phone.receive(hello) else { return XCTFail("hello") }
        // The phone has answered but the Mac has not proven itself yet.
        XCTAssertFalse(phone.canSendEvents)
        XCTAssertThrowsError(try phone.sealEvent(makeEvent())) { XCTAssertEqual($0 as? HandshakeError, .notAuthenticated) }
        guard case .authenticated(let auth) = mac.receive(reply) else { return XCTFail("mac") }
        XCTAssertEqual(phone.receive(auth), .authenticated)
        XCTAssertTrue(phone.canSendEvents)
    }

    func testPhoneRejectsAMacThatDoesNotKnowTheKey() throws {
        // A fake Mac that never saw the pair key: its auth proof is computed with another key.
        var phone = PhoneHandshake(pairKey: pairKey, phoneNonce: phoneNonce)
        _ = phone.receive(.hello(macNonce: macNonce))
        let forged = Pairing.macProof(key: otherKey, macNonce: macNonce, phoneNonce: phoneNonce)
        XCTAssertEqual(phone.receive(.auth(proof: forged)), .failed)
        XCTAssertFalse(phone.canSendEvents)
        XCTAssertThrowsError(try phone.sealEvent(makeEvent()))
    }

    func testPhoneRejectsAPhoneProofReflectedAsMacAuth() {
        var phone = PhoneHandshake(pairKey: pairKey, phoneNonce: phoneNonce)
        _ = phone.receive(.hello(macNonce: macNonce))
        let reflected = Pairing.phoneProof(key: pairKey, macNonce: macNonce, phoneNonce: phoneNonce)
        XCTAssertEqual(phone.receive(.auth(proof: reflected)), .failed)
        XCTAssertFalse(phone.canSendEvents)
    }

    func testPhoneIgnoresAuthThatArrivesWithoutAHello() {
        var phone = PhoneHandshake(pairKey: pairKey, phoneNonce: phoneNonce)
        XCTAssertEqual(phone.receive(.auth(proof: Data(repeating: 0, count: 32))), .failed)
        XCTAssertFalse(phone.canSendEvents)
    }

    func testPhoneFailureIsSticky() {
        var phone = PhoneHandshake(pairKey: pairKey, phoneNonce: phoneNonce)
        _ = phone.receive(.hello(macNonce: macNonce))
        XCTAssertEqual(phone.receive(.auth(proof: Data(repeating: 0, count: 32))), .failed)
        // A correct proof arriving afterwards must not resurrect the link.
        let good = Pairing.macProof(key: pairKey, macNonce: macNonce, phoneNonce: phoneNonce)
        XCTAssertNotEqual(phone.receive(.auth(proof: good)), .authenticated)
        XCTAssertFalse(phone.canSendEvents)
    }

    func testPhoneTreatsAuthFailedAsFailure() {
        var phone = PhoneHandshake(pairKey: pairKey, phoneNonce: phoneNonce)
        _ = phone.receive(.hello(macNonce: macNonce))
        XCTAssertEqual(phone.receive(.authFailed), .failed)
        XCTAssertFalse(phone.canSendEvents)
    }

    func testPhoneRejectsBadHelloNonceLength() {
        for length in [0, 15, 17] {
            var phone = PhoneHandshake(pairKey: pairKey, phoneNonce: phoneNonce)
            XCTAssertEqual(phone.receive(.hello(macNonce: Data(repeating: 1, count: length))), .failed, "length \(length)")
        }
    }

    func testUnpairedPhoneNeverAuthenticates() {
        var phone = PhoneHandshake(pairKey: nil, phoneNonce: phoneNonce)
        XCTAssertFalse(phone.canSendEvents)
        XCTAssertEqual(phone.receive(.hello(macNonce: macNonce)), .failed)
        XCTAssertFalse(phone.canSendEvents)
    }

    func testPhoneWithAMalformedNonceNeverAuthenticates() {
        var phone = PhoneHandshake(pairKey: pairKey, phoneNonce: Data(repeating: 2, count: 8))
        XCTAssertEqual(phone.receive(.hello(macNonce: macNonce)), .failed)
        XCTAssertFalse(phone.canSendEvents)
    }

    func testPhoneDropsPlainStatusBeforeAuthAndDeliversSealedAfter() throws {
        var phone = PhoneHandshake(pairKey: pairKey, phoneNonce: phoneNonce)
        let status = ControlMessage.status(ReceiverStatus(ready: true, appName: "Notes", focusEpoch: 1))
        let ack = ControlMessage.ack(Ack(eventId: UUID(), result: .posted))
        XCTAssertEqual(phone.receive(status), .none)
        _ = phone.receive(.hello(macNonce: macNonce))
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
        var early = PhoneHandshake(pairKey: pairKey, phoneNonce: phoneNonce)
        _ = early.receive(.hello(macNonce: macNonce))
        let macToPhone = SessionCrypto(pairKey: pairKey, macNonce: macNonce, phoneNonce: phoneNonce, direction: .macToPhone)
        let status = ControlMessage.status(ReceiverStatus(ready: true, appName: "Notes", focusEpoch: 1))
        let sealedStatus = ControlMessage.sealed(try macToPhone.seal(ControlCodec.encode(status)))
        XCTAssertEqual(early.receive(sealedStatus), .failed)

        // Only ack and status may live inside; a sealed authFailed or nested sealed is a violation.
        for inner in [ControlMessage.authFailed, .hello(macNonce: macNonce), .sealed(Data([1, 2, 3]))] {
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
        let p2m = SessionCrypto(pairKey: pairKey, macNonce: macNonce, phoneNonce: phoneNonce, direction: .phoneToMac)
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
        var early = MacHandshake(pairKey: pairKey, macNonce: macNonce)
        _ = early.begin()
        let status = ControlMessage.status(ReceiverStatus(ready: false, appName: nil, focusEpoch: 0))
        XCTAssertThrowsError(try early.sealControl(status)) { XCTAssertEqual($0 as? HandshakeError, .notAuthenticated) }
        let (mac, _, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        for bad in [ControlMessage.authFailed, .hello(macNonce: macNonce), .auth(proof: Data(repeating: 0, count: 32)),
                    .pairAccept(publicKey: Data()), .sealed(Data())] {
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
        var early = PhoneHandshake(pairKey: pairKey, phoneNonce: phoneNonce)
        XCTAssertEqual(early.receive(.bye), .none)
        _ = early.receive(.hello(macNonce: macNonce))
        XCTAssertEqual(early.receive(.bye), .none)
        var (_, phone, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        XCTAssertEqual(phone.receive(.bye), .failed)
        XCTAssertFalse(phone.canSendEvents)
    }

    func testSealedByeBeforeAuthFailsThePhone() throws {
        var early = PhoneHandshake(pairKey: pairKey, phoneNonce: phoneNonce)
        _ = early.receive(.hello(macNonce: macNonce))
        let macToPhone = SessionCrypto(pairKey: pairKey, macNonce: macNonce, phoneNonce: phoneNonce, direction: .macToPhone)
        XCTAssertEqual(early.receive(.sealed(try macToPhone.seal(ControlCodec.encode(.bye)))), .failed)
    }

    func testMacCannotSealByeBeforeAuth() {
        var early = MacHandshake(pairKey: pairKey, macNonce: macNonce)
        _ = early.begin()
        XCTAssertThrowsError(try early.sealControl(.bye)) { XCTAssertEqual($0 as? HandshakeError, .notAuthenticated) }
    }

    func testSealControlRejectsOtherInnerMessagesStill() throws {
        let (mac, _, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        for bad in [ControlMessage.authFailed, .hello(macNonce: macNonce), .auth(proof: Data(repeating: 0, count: 32)),
                    .pairAccept(publicKey: Data()), .sealed(Data())] {
            XCTAssertThrowsError(try mac.sealControl(bad)) { XCTAssertEqual($0 as? HandshakeError, .invalidControlMessage) }
        }
        for good in [ControlMessage.ack(Ack(eventId: UUID(), result: .pong)),
                     .status(ReceiverStatus(ready: true, appName: nil, focusEpoch: 1)), .bye] {
            XCTAssertNoThrow(try mac.sealControl(good))
        }
        // The phone still fails on a sealed inner message that is not ack, status or bye.
        let macToPhone = SessionCrypto(pairKey: pairKey, macNonce: macNonce, phoneNonce: phoneNonce, direction: .macToPhone)
        for inner in [ControlMessage.authFailed, .hello(macNonce: macNonce), .sealed(Data([1, 2, 3]))] {
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
        var waiting = PhoneHandshake(pairKey: pairKey, phoneNonce: phoneNonce)
        _ = waiting.receive(.hello(macNonce: macNonce))
        XCTAssertEqual(waiting.receive(.hello(macNonce: macNonce)), .failed)
        let good = Pairing.macProof(key: pairKey, macNonce: macNonce, phoneNonce: phoneNonce)
        XCTAssertNotEqual(waiting.receive(.auth(proof: good)), .authenticated)
        XCTAssertFalse(waiting.canSendEvents)
        var (_, authed, _, _) = handshake(macKey: pairKey, phoneKey: pairKey)
        XCTAssertEqual(authed.receive(.hello(macNonce: Data(repeating: 9, count: 16))), .failed)
        XCTAssertFalse(authed.canSendEvents)
    }

    func testBeginOnAFailedMacDoesNotReportTheFailureAgain() {
        var mac = MacHandshake(pairKey: pairKey, macNonce: macNonce)
        _ = mac.begin()
        XCTAssertEqual(mac.receive(.event(makeEvent())), .authFailed)
        XCTAssertEqual(mac.begin(), .none)
        // A Mac that failed at init (bad own nonce) reports it exactly once, from begin().
        var broken = MacHandshake(pairKey: pairKey, macNonce: Data(count: 3))
        XCTAssertEqual(broken.begin(), .authFailed)
        XCTAssertEqual(broken.begin(), .none)
    }

    func testMacWritesNoAppNameBeforePhoneVerified() {
        var mac = MacHandshake(pairKey: pairKey, macNonce: macNonce)
        XCTAssertNil(mac.statusToSend(appName: "Notes"))
        _ = mac.begin()
        XCTAssertNil(mac.statusToSend(appName: "Notes"))
        let phoneProof = Pairing.phoneProof(key: pairKey, macNonce: macNonce, phoneNonce: phoneNonce)
        guard case .authenticated = mac.receive(.helloReply(phoneNonce: phoneNonce, proof: phoneProof)) else { return XCTFail() }
        XCTAssertEqual(mac.statusToSend(appName: "Notes"), "Notes")
        XCTAssertNil(mac.statusToSend(appName: nil))
    }

    func testMacAuthReplyIsAValidMacProof() {
        var mac = MacHandshake(pairKey: pairKey, macNonce: macNonce)
        _ = mac.begin()
        let proof = Pairing.phoneProof(key: pairKey, macNonce: macNonce, phoneNonce: phoneNonce)
        let expected = Pairing.macProof(key: pairKey, macNonce: macNonce, phoneNonce: phoneNonce)
        XCTAssertEqual(mac.receive(.helloReply(phoneNonce: phoneNonce, proof: proof)), .authenticated(reply: .auth(proof: expected)))
    }

    func testRevokedPairingCannotAuthenticate() {
        // The Mac deleted its pairing (pairKey nil); the same iPhone still holds the old key.
        let result = handshake(macKey: nil, phoneKey: pairKey)
        XCTAssertEqual(result.macOut, .authFailed)
        XCTAssertFalse(result.mac.isAuthenticated)
        XCTAssertNil(result.mac.statusToSend(appName: "Notes"))
        XCTAssertFalse(result.phone.canSendEvents)
    }

    func testMacRejectsHelloReplyWithBadLengths() {
        let proof = Pairing.phoneProof(key: pairKey, macNonce: macNonce, phoneNonce: phoneNonce)
        let cases: [(Data, Data)] = [
            (Data(repeating: 2, count: 15), proof), (Data(repeating: 2, count: 17), proof), (Data(), proof),
            (phoneNonce, proof.dropLast()), (phoneNonce, proof + [0]), (phoneNonce, Data())
        ]
        for (nonce, bad) in cases {
            var mac = MacHandshake(pairKey: pairKey, macNonce: macNonce)
            _ = mac.begin()
            XCTAssertEqual(mac.receive(.helloReply(phoneNonce: nonce, proof: bad)), .authFailed)
            XCTAssertFalse(mac.isAuthenticated)
        }
    }

    func testMacRejectsHelloReplyBeforeItSentHello() {
        var mac = MacHandshake(pairKey: pairKey, macNonce: macNonce)
        let proof = Pairing.phoneProof(key: pairKey, macNonce: macNonce, phoneNonce: phoneNonce)
        XCTAssertEqual(mac.receive(.helloReply(phoneNonce: phoneNonce, proof: proof)), .authFailed)
    }

    func testMacRejectsAHelloReplyForAnotherSession() {
        // The proof was computed over an old macNonce, as a recorded reply would be.
        var mac = MacHandshake(pairKey: pairKey, macNonce: macNonce)
        _ = mac.begin()
        let stale = Pairing.phoneProof(key: pairKey, macNonce: Data(repeating: 7, count: 16), phoneNonce: phoneNonce)
        XCTAssertEqual(mac.receive(.helloReply(phoneNonce: phoneNonce, proof: stale)), .authFailed)
    }

    func testMacWithABadOwnNonceFailsClosed() {
        var mac = MacHandshake(pairKey: pairKey, macNonce: Data(repeating: 1, count: 4))
        XCTAssertEqual(mac.begin(), .authFailed)
    }

    func testPlaintextEventIsAProtocolViolationBeforeAndAfterAuth() {
        let plain = PeripheralMessage.event(makeEvent())
        var early = MacHandshake(pairKey: pairKey, macNonce: macNonce)
        _ = early.begin()
        XCTAssertEqual(early.receive(plain), .authFailed)
        var authed = handshake(macKey: pairKey, phoneKey: pairKey).mac
        XCTAssertEqual(authed.receive(plain), .authFailed)
    }

    func testSealedBeforeAuthenticationIsAProtocolViolation() throws {
        var mac = MacHandshake(pairKey: pairKey, macNonce: macNonce)
        _ = mac.begin()
        let session = SessionCrypto(pairKey: pairKey, macNonce: macNonce, phoneNonce: phoneNonce, direction: .phoneToMac)
        let sealed = try session.seal(PeripheralCodec.encode(.event(makeEvent())))
        XCTAssertEqual(mac.receive(.sealed(sealed)), .authFailed)
    }

    func testPairingMessagesAreForwardedBeforeAuthAndRejectedAfter() {
        let commitment = Pairing.commitment(phonePublic: publicData(fixedPrivateKey(0x22)))
        let offer = PeripheralMessage.pairOffer(commitment: commitment)
        let reveal = PeripheralMessage.pairReveal(publicKey: publicData(fixedPrivateKey(0x22)))
        var mac = MacHandshake(pairKey: nil, macNonce: macNonce)
        _ = mac.begin()
        XCTAssertEqual(mac.receive(offer), .pairOffer(commitment: commitment))
        XCTAssertEqual(mac.receive(reveal), .pairReveal(publicKey: publicData(fixedPrivateKey(0x22))))
        XCTAssertFalse(mac.isAuthenticated)
        var authed = handshake(macKey: pairKey, phoneKey: pairKey).mac
        XCTAssertEqual(authed.receive(offer), .authFailed)
        var authed2 = handshake(macKey: pairKey, phoneKey: pairKey).mac
        XCTAssertEqual(authed2.receive(reveal), .authFailed)
    }

    func testMalformedPairingPayloadsFailAuth() {
        var mac = MacHandshake(pairKey: nil, macNonce: macNonce)
        _ = mac.begin()
        XCTAssertEqual(mac.receive(.pairOffer(commitment: Data(repeating: 4, count: 31))), .authFailed)
        var mac2 = MacHandshake(pairKey: nil, macNonce: macNonce)
        XCTAssertEqual(mac2.receive(.pairReveal(publicKey: Data(repeating: 4, count: 65))), .authFailed)
        var mac3 = MacHandshake(pairKey: nil, macNonce: macNonce)
        XCTAssertEqual(mac3.receive(.pairReveal(publicKey: Data())), .authFailed)
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
        let session = SessionCrypto(pairKey: pairKey, macNonce: macNonce, phoneNonce: phoneNonce, direction: .phoneToMac)
        let sealed = try session.seal(Data("not json".utf8))
        XCTAssertEqual(mac.receive(.sealed(sealed)), .malformedPayload)
        XCTAssertTrue(mac.isAuthenticated)
    }

    func testSealedNonEventInnerMessageFailsAuth() throws {
        var mac = handshake(macKey: pairKey, phoneKey: pairKey).mac
        let session = SessionCrypto(pairKey: pairKey, macNonce: macNonce, phoneNonce: phoneNonce, direction: .phoneToMac)
        let inner = try PeripheralCodec.encode(.pairReveal(publicKey: publicData(fixedPrivateKey(0x22))))
        XCTAssertEqual(mac.receive(.sealed(try session.seal(inner))), .authFailed)
    }

    func testMacFailureIsStickyAndReportedOnce() {
        var mac = MacHandshake(pairKey: pairKey, macNonce: macNonce)
        _ = mac.begin()
        XCTAssertEqual(mac.receive(.event(makeEvent())), .authFailed)
        let good = Pairing.phoneProof(key: pairKey, macNonce: macNonce, phoneNonce: phoneNonce)
        XCTAssertEqual(mac.receive(.helloReply(phoneNonce: phoneNonce, proof: good)), .none)
        XCTAssertFalse(mac.isAuthenticated)
        XCTAssertNil(mac.statusToSend(appName: "Notes"))
    }

    func testReplayedSealedFromAnEarlierHandshakeFailsInANewOne() throws {
        let first = handshake(macKey: pairKey, phoneKey: pairKey)
        guard case .sealed(let recorded) = try first.phone.sealEvent(makeEvent()) else { return XCTFail() }
        // New session: fresh nonces on both sides.
        var mac = MacHandshake(pairKey: pairKey, macNonce: Data(repeating: 0x41, count: 16))
        var phone = PhoneHandshake(pairKey: pairKey, phoneNonce: Data(repeating: 0x42, count: 16))
        guard case .send(let hello) = mac.begin(), case .send(let reply) = phone.receive(hello),
              case .authenticated = mac.receive(reply) else { return XCTFail("second handshake") }
        XCTAssertEqual(mac.receive(.sealed(recorded)), .authFailed)
    }
}
