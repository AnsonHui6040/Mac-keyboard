import CryptoKit
import XCTest
@testable import RemoteKeyboardCore

final class SessionCryptoTests: XCTestCase {
    private let pairKey = SymmetricKey(data: Data(repeating: 5, count: 32))
    private let macNonce = Data(repeating: 1, count: 16)
    private let phoneNonce = Data(repeating: 2, count: 16)

    private func session(_ key: SymmetricKey? = nil, mac: Data? = nil, phone: Data? = nil) -> SessionCrypto {
        SessionCrypto(pairKey: key ?? pairKey, macNonce: mac ?? macNonce, phoneNonce: phone ?? phoneNonce)
    }

    func testSealOpenRoundTripAndTamperFails() throws {
        let crypto = session()
        let plain = Data("{\"type\":\"event\"}".utf8)
        let sealed = try crypto.seal(plain)
        XCTAssertNotEqual(sealed, plain)
        XCTAssertEqual(try crypto.open(sealed), plain)
        // Layout: 12-byte nonce + ciphertext + 16-byte tag.
        XCTAssertEqual(sealed.count, plain.count + 28)
        for index in [0, 11, 12, sealed.count - 17, sealed.count - 1] {
            var tampered = sealed
            tampered[tampered.startIndex + index] ^= 0x01
            XCTAssertThrowsError(try crypto.open(tampered), "byte \(index)") {
                XCTAssertEqual($0 as? SessionCryptoError, .openFailed)
            }
        }
    }

    func testReplayFromOldSessionFails() throws {
        let old = session()
        let sealed = try old.seal(Data("hello".utf8))
        let freshMacNonce = Data(repeating: 9, count: 16)
        XCTAssertThrowsError(try session(mac: freshMacNonce).open(sealed)) { XCTAssertEqual($0 as? SessionCryptoError, .openFailed) }
        let freshPhoneNonce = Data(repeating: 8, count: 16)
        XCTAssertThrowsError(try session(phone: freshPhoneNonce).open(sealed)) { XCTAssertEqual($0 as? SessionCryptoError, .openFailed) }
    }

    func testSwappedNonceRolesGiveADifferentSession() throws {
        let sealed = try session().seal(Data("x".utf8))
        XCTAssertThrowsError(try session(mac: phoneNonce, phone: macNonce).open(sealed))
    }

    func testOtherPairKeyCannotOpen() throws {
        let sealed = try session().seal(Data("x".utf8))
        let other = SymmetricKey(data: Data(repeating: 6, count: 32))
        XCTAssertThrowsError(try session(other).open(sealed)) { XCTAssertEqual($0 as? SessionCryptoError, .openFailed) }
    }

    func testSealingTwiceGivesDifferentCiphertext() throws {
        let crypto = session()
        let plain = Data("same".utf8)
        XCTAssertNotEqual(try crypto.seal(plain), try crypto.seal(plain))
    }

    func testTooShortOrEmptyInputFailsWithoutCrashing() {
        let crypto = session()
        for bad in [Data(), Data([1]), Data(repeating: 0, count: 27)] {
            XCTAssertThrowsError(try crypto.open(bad)) { XCTAssertEqual($0 as? SessionCryptoError, .openFailed) }
        }
    }

    func testEmptyPlaintextRoundTrips() throws {
        let crypto = session()
        XCTAssertEqual(try crypto.open(try crypto.seal(Data())), Data())
    }

    func testSessionKeyDerivationMatchesSpec() throws {
        let expected = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: pairKey, salt: Data(), info: Data("rk-session".utf8) + macNonce + phoneNonce, outputByteCount: 32)
        let box = try ChaChaPoly.seal(Data("probe".utf8), using: expected)
        XCTAssertEqual(try session().open(box.combined), Data("probe".utf8))
    }
}
