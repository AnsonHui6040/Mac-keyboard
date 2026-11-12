#if DEBUG
import CryptoKit
import XCTest
@testable import RemoteKeyboardCore

final class MeasurePayloadTests: XCTestCase {
    func testMeasureRoundTrip16And157() throws {
        let payload = MeasurePayload(kind: .cursor, dxSixteenths: -1234, seq: 0xDEAD_BEEF, phoneTimeMicros: 0x0102_0304_0506_0708)
        for size in [16, 157] {
            let bytes = payload.encode(padTo: size)
            XCTAssertEqual(bytes.count, size)
            XCTAssertEqual(MeasurePayload.decode(bytes), payload)
        }
    }

    func testLayout() {
        let bytes = MeasurePayload(kind: .rtt, dxSixteenths: 0x0102, seq: 0x0304_0506, phoneTimeMicros: 0x0708_090A_0B0C_0D0E).encode(padTo: 16)
        XCTAssertEqual([UInt8](bytes), [2, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14])
    }

    func testKindRawValues() {
        XCTAssertEqual(MeasurePayload.Kind.burst.rawValue, 1)
        XCTAssertEqual(MeasurePayload.Kind.rtt.rawValue, 2)
        XCTAssertEqual(MeasurePayload.Kind.cursor.rawValue, 3)
        XCTAssertEqual(MeasurePayload.Kind.heartbeat.rawValue, 4)
    }

    func testDecodeRefusesOtherLengthsUnknownKindsAndNonZeroFill() {
        let good = MeasurePayload(kind: .burst, dxSixteenths: 0, seq: 1, phoneTimeMicros: 2)
        XCTAssertNil(MeasurePayload.decode(Data()))
        XCTAssertNil(MeasurePayload.decode(good.encode(padTo: 16).dropLast()))
        XCTAssertNil(MeasurePayload.decode(good.encode(padTo: 157) + [0]))
        var unknown = good.encode(padTo: 16)
        unknown[0] = 9
        XCTAssertNil(MeasurePayload.decode(unknown))
        var reserved = good.encode(padTo: 16)
        reserved[1] = 1
        XCTAssertNil(MeasurePayload.decode(reserved))
        var padded = good.encode(padTo: 157)
        padded[100] = 1
        XCTAssertNil(MeasurePayload.decode(padded))
    }

    func testEchoRoundTrip() {
        let echo = MeasureEchoPayload(seq: 77, phoneTimeMicros: 123_456_789_012, macHoldMicros: 4321, macTimeMicros: 987_654_321_098)
        let bytes = echo.encode()
        XCTAssertEqual(bytes.count, 24)
        XCTAssertEqual(MeasureEchoPayload.length, 24)
        XCTAssertEqual(MeasureEchoPayload.decode(bytes), echo)
        XCTAssertNil(MeasureEchoPayload.decode(bytes.dropLast()))
        XCTAssertNil(MeasureEchoPayload.decode(bytes + [0]))
        XCTAssertNil(MeasureEchoPayload.decode(bytes.prefix(16)), "the 16-byte reply of the earlier layout is refused")
    }

    func testEchoLayout() {
        let echo = MeasureEchoPayload(seq: 0x0102_0304, phoneTimeMicros: 0x0506_0708_090A_0B0C, macHoldMicros: 0x0D0E_0F10, macTimeMicros: 0x1112_1314_1516_1718)
        XCTAssertEqual(
            [UInt8](echo.encode()),
            [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18])
    }

    func testSealedEchoIsFortyNineBytesAndATamperedOneIsRefused() throws {
        let pairKey = SymmetricKey(data: Data(repeating: 7, count: 32))
        var mac = makeMac(pairKey, nonce: Data(repeating: 1, count: 16))
        var phone = makePhone(pairKey, nonce: Data(repeating: 2, count: 16))
        guard case .send(let hello) = mac.begin(), case .send(let reply) = phone.receive(hello),
              case .authenticated(let auth, _) = mac.receive(reply), phone.receive(auth) == .authenticated,
              let macChannels = mac.takeChannelSet(), let phoneChannels = phone.takeChannelSet()
        else { return XCTFail("handshake") }
        let echo = MeasureEchoPayload(seq: 9, phoneTimeMicros: 11, macHoldMicros: 13, macTimeMicros: 17)
        let sealed = try macChannels.sealer(.measureM2P).seal(echo.encode())
        XCTAssertEqual(sealed.count, 49, "1 magic + 8 counter + 24 plaintext + 16 tag")
        // A flipped bit in the Mac time (the last plaintext bytes) fails authentication; a refused packet leaves the window alone.
        var tampered = sealed
        tampered[9 + 20] ^= 0x01
        let opener = phoneChannels.opener(.measureM2P)
        XCTAssertEqual(opener.open(tampered), .failure(.authFailed))
        let opened = try opener.open(sealed).get()
        XCTAssertEqual(MeasureEchoPayload.decode(opened), echo)
    }

    func testMeasureClockNeverGoesBack() {
        let a = MeasureClock.nowMicros()
        let b = MeasureClock.nowMicros()
        XCTAssertGreaterThanOrEqual(b, a)
    }
}
#endif
