#if DEBUG
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
        let echo = MeasureEchoPayload(seq: 77, phoneTimeMicros: 123_456_789_012, macHoldMicros: 4321)
        let bytes = echo.encode()
        XCTAssertEqual(bytes.count, 16)
        XCTAssertEqual(MeasureEchoPayload.decode(bytes), echo)
        XCTAssertNil(MeasureEchoPayload.decode(bytes.dropLast()))
        XCTAssertNil(MeasureEchoPayload.decode(bytes + [0]))
    }

    func testMeasureClockNeverGoesBack() {
        let a = MeasureClock.nowMicros()
        let b = MeasureClock.nowMicros()
        XCTAssertGreaterThanOrEqual(b, a)
    }
}
#endif
