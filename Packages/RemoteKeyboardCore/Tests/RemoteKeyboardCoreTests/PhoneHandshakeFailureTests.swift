import CryptoKit
import XCTest
@testable import RemoteKeyboardCore

/// Every failing branch of `PhoneHandshake.receive` records exactly one `PhoneHandshakeFailure`.
final class PhoneHandshakeFailureTests: XCTestCase {
    private let pairKey = SymmetricKey(data: Data(repeating: 5, count: 32))
    private let hostNonce = Data(repeating: 1, count: 16)
    private let phoneNonce = Data(repeating: 2, count: 16)
    private let status = ControlMessage.status(ReceiverStatus(ready: true, appName: "Notes", focusEpoch: 1))

    private func authenticated() -> (mac: MacHandshake, phone: PhoneHandshake) {
        var mac = makeMac(pairKey, nonce: hostNonce)
        var phone = makePhone(pairKey, nonce: phoneNonce)
        guard case .send(let hello) = mac.begin(), case .send(let reply) = phone.receive(hello),
              case .authenticated(let auth, _) = mac.receive(reply) else { XCTFail("handshake did not start"); return (mac, phone) }
        XCTAssertEqual(phone.receive(auth), .authenticated)
        return (mac, phone)
    }

    private func awaitingAuth() -> PhoneHandshake {
        var phone = makePhone(pairKey, nonce: phoneNonce)
        _ = phone.receive(helloMessage(hostNonce))
        return phone
    }

    private var macToPhone: SessionCrypto {
        SessionCrypto(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, direction: .macToPhone)
    }

    func testNoFailureWhileTheHandshakeSucceeds() {
        XCTAssertNil(authenticated().phone.failure)
        XCTAssertNil(awaitingAuth().failure)
    }

    func testMalformedHello() {
        var phone = makePhone(pairKey, nonce: phoneNonce)
        XCTAssertEqual(phone.receive(.hello(hostId: Fixture.hostId, hostNonce: Data(repeating: 1, count: 3))), .failed)
        XCTAssertEqual(phone.failure, .malformedHello)
    }

    func testBadOwnNonce() {
        var phone = makePhone(pairKey, nonce: Data(repeating: 2, count: 3))
        XCTAssertEqual(phone.receive(helloMessage(hostNonce)), .failed)
        XCTAssertEqual(phone.failure, .badOwnNonce)
    }

    func testSecondHelloBeforeAndAfterAuth() {
        var early = awaitingAuth()
        XCTAssertEqual(early.receive(helloMessage(hostNonce)), .failed)
        XCTAssertEqual(early.failure, .secondHello)
        var late = authenticated().phone
        XCTAssertEqual(late.receive(helloMessage(hostNonce)), .failed)
        XCTAssertEqual(late.failure, .secondHello)
    }

    func testAuthOutOfOrder() {
        var phone = makePhone(pairKey, nonce: phoneNonce)
        XCTAssertEqual(phone.receive(.auth(proof: Data(repeating: 0, count: 32))), .failed)
        XCTAssertEqual(phone.failure, .authOutOfOrder)
    }

    func testBadHostProof() {
        var phone = awaitingAuth()
        XCTAssertEqual(phone.receive(.auth(proof: Data(repeating: 0, count: 32))), .failed)
        XCTAssertEqual(phone.failure, .badHostProof)
    }

    func testAuthFailedReceived() {
        var phone = authenticated().phone
        XCTAssertEqual(phone.receive(.authFailed), .failed)
        XCTAssertEqual(phone.failure, .authFailedReceived)
    }

    func testPlainControlAfterAuth() {
        let cases: [(ControlMessage, PhoneHandshakeFailure.ControlKind)] = [
            (.ack(Ack(eventId: UUID(), result: .posted)), .ack), (status, .status), (.bye, .bye)]
        for (message, kind) in cases {
            var phone = authenticated().phone
            XCTAssertEqual(phone.receive(message), .failed)
            XCTAssertEqual(phone.failure, .plainControlAfterAuth(kind: kind))
        }
    }

    func testPlainControlBeforeAuthIsDroppedWithoutFailure() {
        var phone = awaitingAuth()
        XCTAssertEqual(phone.receive(status), .none)
        XCTAssertNil(phone.failure)
    }

    func testSealedBeforeAuth() throws {
        var phone = awaitingAuth()
        XCTAssertEqual(phone.receive(.sealed(try macToPhone.seal(ControlCodec.encode(status)))), .failed)
        XCTAssertEqual(phone.failure, .sealedBeforeAuth)
    }

    func testSealedOpenFailedCarriesTheLength() {
        var phone = authenticated().phone
        XCTAssertEqual(phone.receive(.sealed(Data(repeating: 9, count: 40))), .failed)
        XCTAssertEqual(phone.failure, .sealedOpenFailed(length: 40))
        XCTAssertEqual(phone.failure?.length, 40)
    }

    func testSealedDecodeFailedCarriesTheLength() throws {
        var phone = authenticated().phone
        let sealed = try macToPhone.seal(Data("not json".utf8))
        XCTAssertEqual(phone.receive(.sealed(sealed)), .failed)
        XCTAssertEqual(phone.failure, .sealedDecodeFailed(length: sealed.count))
    }

    func testSealedUnexpectedInner() throws {
        var phone = authenticated().phone
        XCTAssertEqual(phone.receive(.sealed(try macToPhone.seal(ControlCodec.encode(.authFailed)))), .failed)
        XCTAssertEqual(phone.failure, .sealedUnexpectedInner)
    }

    func testFirstFailureIsKept() {
        var phone = authenticated().phone
        _ = phone.receive(.authFailed)
        _ = phone.receive(helloMessage(hostNonce))
        XCTAssertEqual(phone.failure, .authFailedReceived)
    }

    func testReasonWordsAreFixedAndCarryNoPayload() {
        XCTAssertEqual(PhoneHandshakeFailure.sealedOpenFailed(length: 12).reason, "sealedOpenFailed")
        XCTAssertEqual(PhoneHandshakeFailure.plainControlAfterAuth(kind: .bye).reason, "plainControlAfterAuth.bye")
        XCTAssertNil(PhoneHandshakeFailure.badHostProof.length)
    }
}
