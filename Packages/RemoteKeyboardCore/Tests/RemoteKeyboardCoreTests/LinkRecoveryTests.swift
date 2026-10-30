import CryptoKit
import XCTest
@testable import RemoteKeyboardCore

final class LinkRecoveryTests: XCTestCase {
    private let pairKey = SymmetricKey(data: Data(repeating: 5, count: 32))
    private let macNonce = Data(repeating: 1, count: 16)
    private let phoneNonce = Data(repeating: 2, count: 16)

    // MARK: HandshakeProgress as the phone reports it

    func testProgressFollowsTheHandshake() {
        var phone = PhoneHandshake(pairKey: pairKey, phoneNonce: phoneNonce)
        XCTAssertEqual(phone.progress, .inProgress)
        _ = phone.receive(.hello(macNonce: macNonce))
        XCTAssertEqual(phone.progress, .inProgress, "waiting for the Mac's proof is still in progress")
        let proof = Pairing.macProof(key: pairKey, macNonce: macNonce, phoneNonce: phoneNonce)
        XCTAssertEqual(phone.receive(.auth(proof: proof)), .authenticated)
        XCTAssertEqual(phone.progress, .authenticated)
        XCTAssertEqual(phone.receive(.authFailed), .failed)
        XCTAssertEqual(phone.progress, .failed)
    }

    func testUnpairedPhoneFailsOnTheFirstHello() {
        var phone = PhoneHandshake(pairKey: nil, phoneNonce: phoneNonce)
        XCTAssertEqual(phone.progress, .inProgress)
        _ = phone.receive(.hello(macNonce: macNonce))
        XCTAssertEqual(phone.progress, .failed)
    }

    // MARK: Reset on appearance

    func testResetOnAppearOnlyForAConnectedLinkWithAFailedHandshake() {
        XCTAssertTrue(LinkRecovery.shouldResetOnAppear(linkConnected: true, handshake: .failed, hasPairKey: true))
        XCTAssertFalse(LinkRecovery.shouldResetOnAppear(linkConnected: true, handshake: .inProgress, hasPairKey: true),
                       "never reset while a handshake is still running")
        XCTAssertFalse(LinkRecovery.shouldResetOnAppear(linkConnected: true, handshake: .authenticated, hasPairKey: true),
                       "a live authenticated link is probed, not reset")
        XCTAssertFalse(LinkRecovery.shouldResetOnAppear(linkConnected: true, handshake: nil, hasPairKey: true))
        XCTAssertFalse(LinkRecovery.shouldResetOnAppear(linkConnected: false, handshake: .failed, hasPairKey: true),
                       "nothing to reset when the link is not connected")
    }

    func testUnpairedKeyboardIsNotResetOnAppear() {
        XCTAssertFalse(LinkRecovery.shouldResetOnAppear(linkConnected: true, handshake: .failed, hasPairKey: false),
                       "without a key the handshake fails by itself on every connection; a reset would only loop")
    }

    // MARK: Reset right after a failure

    func testFailureWithAPairKeyResetsTheLink() {
        XCTAssertTrue(LinkRecovery.shouldResetAfterHandshakeFailure(hasPairKey: true))
    }

    func testFailureWithoutAPairKeyDoesNotReset() {
        XCTAssertFalse(LinkRecovery.shouldResetAfterHandshakeFailure(hasPairKey: false))
    }
}
