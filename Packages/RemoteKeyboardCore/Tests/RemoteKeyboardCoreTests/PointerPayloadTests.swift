import CryptoKit
import XCTest
@testable import RemoteKeyboardCore

final class PointerPayloadTests: XCTestCase {
    func testEncodeLayoutIsSixteenBytesBigEndian() {
        let payload = PointerPayload(
            opcode: .move, buttons: 0x01, dx: 0x0102, dy: -2, dt: 0x0304, actionId: 0, arg: 0, status: 0x01, buttonSeq: 0x0506)
        XCTAssertEqual(
            [UInt8](payload.encode()),
            [0x01, 0x01, 0x01, 0x02, 0xFF, 0xFE, 0x03, 0x04, 0, 0, 0, 0, 0x00, 0x01, 0x05, 0x06])
    }

    func testRoundTripOfEveryOpcode() {
        let opcodes: [PointerPayload.Opcode] = [.move, .scroll, .click, .buttonState, .heartbeat]
        for opcode in opcodes {
            var payload = PointerPayload(opcode: opcode, buttons: 0x01, dx: -1234, dy: 4321, dt: 800, buttonSeq: 65_535)
            if opcode == .click { payload.arg = PointerPayload.clickArg(count: 1) }
            XCTAssertEqual(PointerPayload.decode(payload.encode()), payload, "\(opcode)")
        }
    }

    func testWrongLengthIsRejected() {
        let good = PointerPayload(opcode: .move, buttons: 0, dx: 1, dy: 1, dt: 1, buttonSeq: 0).encode()
        XCTAssertNil(PointerPayload.decode(good.dropLast()))
        XCTAssertNil(PointerPayload.decode(good + [0]))
        XCTAssertNil(PointerPayload.decode(Data()))
    }

    func testReservedBitsMustBeZero() {
        let base = PointerPayload(opcode: .move, buttons: 0, dx: 1, dy: 1, dt: 1, buttonSeq: 0)
        // buttons bit2 and bit3
        for bit in [UInt8(0x04), 0x08] {
            var bytes = [UInt8](base.encode())
            bytes[1] |= bit
            XCTAssertNil(PointerPayload.decode(Data(bytes)), "buttons reserved \(bit)")
        }
        // status bit3 to bit7
        for shift in 3...7 {
            var bytes = [UInt8](base.encode())
            bytes[13] |= UInt8(1 << shift)
            XCTAssertNil(PointerPayload.decode(Data(bytes)), "status bit \(shift)")
        }
        // status bit0..2 and the touch-count nibble are allowed
        var allowed = [UInt8](base.encode())
        allowed[13] = 0x07
        allowed[1] = 0xF3
        XCTAssertNotNil(PointerPayload.decode(Data(allowed)))
    }

    func testUnknownOpcodeIsRejected() {
        for code: UInt8 in [0x00, 0x03, 0x13, 0x20, 0xFF] {
            var bytes = [UInt8](PointerPayload(opcode: .move, buttons: 0, dx: 0, dy: 0, dt: 0, buttonSeq: 0).encode())
            bytes[0] = code
            XCTAssertNil(PointerPayload.decode(Data(bytes)), "opcode \(code)")
        }
    }

    func testScrollAndClickArgumentsAreChecked() {
        var scroll = [UInt8](PointerPayload(opcode: .scroll, buttons: 0, dx: 0, dy: 0, dt: 0, buttonSeq: 0).encode())
        scroll[12] = 4
        XCTAssertNil(PointerPayload.decode(Data(scroll)))
        for (phase, raw) in [(PointerPayload.ScrollPhase.changed, UInt8(0)), (.began, 1), (.ended, 2), (.cancelled, 3)] {
            scroll[12] = raw
            XCTAssertEqual(PointerPayload.decode(Data(scroll))?.scrollPhase, phase)
        }
        var click = [UInt8](PointerPayload(opcode: .click, buttons: 0, dx: 0, dy: 0, dt: 0, buttonSeq: 0).encode())
        for bad: UInt8 in [0x00, 0x02, 0x04, 0x41, 0x11 | 0x08] {
            click[12] = bad
            XCTAssertNil(PointerPayload.decode(Data(click)), "click arg \(bad)")
        }
        click[12] = PointerPayload.clickArg(count: 1)
        XCTAssertEqual(click[12], 0x10)
        XCTAssertEqual(PointerPayload.decode(Data(click))?.clickCount, 1)
    }

    func testPayloadTravelsThroughTheEncryptedPointerChannel() throws {
        let pairKey = SymmetricKey(data: Data(repeating: 9, count: 32))
        let macNonce = Data(repeating: 1, count: 16), phoneNonce = Data(repeating: 2, count: 16)
        let phone = ChannelSet(pairKey: pairKey, macNonce: macNonce, phoneNonce: phoneNonce)
        let mac = ChannelSet(pairKey: pairKey, macNonce: macNonce, phoneNonce: phoneNonce)
        let payload = PointerPayload(opcode: .move, buttons: 1, dx: 321, dy: -123, dt: 160, buttonSeq: 3)
        let packet = try phone.sealer(.pointer).seal(payload.encode())
        XCTAssertEqual(packet.count, 41)
        XCTAssertEqual(packet[0], 0x03)
        XCTAssertEqual(PointerPayload.decode(try mac.opener(.pointer).open(packet).get()), payload)
        XCTAssertEqual(mac.opener(.pointer).open(packet), .failure(.replayed), "a replay is refused")
    }
}
