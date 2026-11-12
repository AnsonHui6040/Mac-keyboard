import CryptoKit
import XCTest
@testable import RemoteKeyboardCore

final class CounterChannelTests: XCTestCase {
    private let pairKey = SymmetricKey(data: Data(repeating: 5, count: 32))
    private let hostNonce = Data(repeating: 1, count: 16)
    private let phoneNonce = Data(repeating: 2, count: 16)

    private func makeSet(mac: UInt8 = 1, phone: UInt8 = 2) -> ChannelSet {
        ChannelSet(pairKey: pairKey, hostNonce: Data(repeating: mac, count: 16), phoneNonce: Data(repeating: phone, count: 16))
    }

    private func counterBytes(_ counter: UInt64) -> Data {
        var be = counter.bigEndian
        return Data(bytes: &be, count: 8)
    }

    /// Every kind of this build with the constants the spec fixes for it (§6.1).
    private var expectedKinds: [(kind: CounterChannel.Kind, magic: UInt8, info: String, prefix: String)] {
        var kinds: [(CounterChannel.Kind, UInt8, String, String)] = [(.pointer, 0x03, "rk-pointer-p2m", "PTR3")]
        #if DEBUG
        kinds.append((.measureP2M, 0x7E, "rk-measure-p2m", "MSR3"))
        kinds.append((.measureM2P, 0x7E, "rk-measure-m2p", "MSE3"))
        #endif
        return kinds
    }

    private func plaintext(length: Int, fill: UInt8 = 0xA5) -> Data { Data(repeating: fill, count: length) }

    /// The shortest plaintext a kind accepts: 16 bytes, except a measurement reply (24 bytes since it carries the Mac time).
    private func standardLength(_ kind: CounterChannel.Kind) -> Int {
        #if DEBUG
        if kind == .measureM2P { return 24 }
        #endif
        return 16
    }

    // MARK: Packet shape

    func testPacketSizes() throws {
        let set = makeSet()
        XCTAssertEqual(try set.sealer(.pointer).seal(plaintext(length: 16)).count, 41)
        #if DEBUG
        XCTAssertEqual(try set.sealer(.measureP2M).seal(plaintext(length: 16)).count, 41)
        XCTAssertEqual(try set.sealer(.measureP2M).seal(plaintext(length: 157)).count, 182)
        XCTAssertEqual(try set.sealer(.measureM2P).seal(plaintext(length: 24)).count, 49)
        XCTAssertThrowsError(try set.sealer(.measureM2P).seal(plaintext(length: 16))) {
            XCTAssertEqual($0 as? ChannelError, .badLength, "the 16-byte reply of the earlier layout is refused")
        }
        #endif
    }

    func testSealerRefusesPlaintextOfAnotherLength() throws {
        let set = makeSet()
        XCTAssertThrowsError(try set.sealer(.pointer).seal(plaintext(length: 15))) {
            XCTAssertEqual($0 as? ChannelError, .badLength)
        }
        XCTAssertThrowsError(try set.sealer(.pointer).seal(plaintext(length: 157))) {
            XCTAssertEqual($0 as? ChannelError, .badLength)
        }
        XCTAssertEqual(try set.sealer(.pointer).lastCounter, 0, "a refused plaintext does not use a counter")
    }

    func testNonceIsPrefixPlusCounter() throws {
        let set = makeSet()
        for expected in expectedKinds {
            let key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: pairKey, salt: Data(), info: Data(expected.info.utf8) + hostNonce + phoneNonce, outputByteCount: 32)
            let sealer = set.sealer(expected.kind)
            let plain = plaintext(length: standardLength(expected.kind), fill: expected.magic)
            for counter in UInt64(1)...3 {
                let packet = try sealer.seal(plain)
                let header = Data([expected.magic]) + counterBytes(counter)
                let nonce = try ChaChaPoly.Nonce(data: Data(expected.prefix.utf8) + counterBytes(counter))
                let box = try ChaChaPoly.seal(plain, using: key, nonce: nonce, authenticating: header)
                XCTAssertEqual(packet, header + box.ciphertext + box.tag, "\(expected.info) counter \(counter)")
                XCTAssertEqual(sealer.lastCounter, counter)
            }
        }
    }

    func testRoundTripBetweenTwoSetsOfOneHandshake() throws {
        let phone = makeSet(), mac = makeSet()
        for expected in expectedKinds {
            let plain = plaintext(length: standardLength(expected.kind), fill: 7)
            let packet = try phone.sealer(expected.kind).seal(plain)
            XCTAssertEqual(try mac.opener(expected.kind).open(packet).get(), plain)
        }
    }

    // MARK: Tampering

    func testTamperAnyByteRejected() throws {
        var cases: [(CounterChannel.Kind, Int)] = [(.pointer, 16)]
        #if DEBUG
        cases.append((.measureP2M, 157))
        #endif
        for (kind, length) in cases {
            let phone = ChannelSet(
                pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, startingCounter: 1000)
            let packet = try phone.sealer(kind).seal(plaintext(length: length))
            XCTAssertEqual(packet.count, length + 25)
            for index in 0..<packet.count {
                for bit in 0..<8 {
                    var bad = packet
                    bad[index] ^= UInt8(1 << bit)
                    // A fresh receiver each time, so the replay window cannot be the reason for a refusal.
                    let result = makeSet().opener(kind).open(bad)
                    switch result {
                    case .failure(let error):
                        XCTAssertTrue(error == .authFailed || error == .badMagic, "byte \(index) bit \(bit): \(error)")
                    case .success:
                        XCTFail("byte \(index) bit \(bit) was accepted")
                    }
                }
            }
            XCTAssertEqual(try makeSet().opener(kind).open(packet).get(), plaintext(length: length), "the untouched packet opens")
        }
    }

    func testWrongLengthRejected() throws {
        let set = makeSet()
        let packet = try set.sealer(.pointer).seal(plaintext(length: 16))
        let opener = makeSet().opener(.pointer)
        XCTAssertEqual(opener.open(packet.dropLast()), .failure(.badLength))
        XCTAssertEqual(opener.open(packet + [0]), .failure(.badLength))
        XCTAssertEqual(opener.open(Data()), .failure(.badLength))
    }

    func testOpenerRefusesAnotherKindsMagic() throws {
        let set = makeSet()
        let packet = try set.sealer(.pointer).seal(plaintext(length: 16))
        #if DEBUG
        XCTAssertEqual(makeSet().opener(.measureP2M).open(packet), .failure(.badMagic))
        #endif
        var forged = packet
        forged[0] = 0x04
        XCTAssertEqual(makeSet().opener(.pointer).open(forged), .failure(.badMagic))
    }

    // MARK: Keys

    func testKeysDifferPerKindAndFromSessionKeys() {
        let set = makeSet()
        var keys: [Data] = CounterChannel.Kind.allCases.map { set.keyDataForTesting($0) }
        XCTAssertEqual(Set(keys).count, CounterChannel.Kind.allCases.count)
        for direction in [SessionCrypto.Direction.phoneToMac, .macToPhone] {
            let info = direction == .phoneToMac ? "rk-session-p2m" : "rk-session-m2p"
            let session = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: pairKey, salt: Data(), info: Data(info.utf8) + hostNonce + phoneNonce, outputByteCount: 32)
            keys.append(session.withUnsafeBytes { Data($0) })
        }
        XCTAssertEqual(Set(keys).count, keys.count, "no channel key equals another channel key or a session key")
    }

    func testNewHandshakeNoncesGiveNewKey() {
        let first = makeSet(), second = makeSet(mac: 9, phone: 2), third = makeSet(mac: 1, phone: 9)
        for kind in CounterChannel.Kind.allCases {
            let keys = [first, second, third].map { $0.keyDataForTesting(kind) }
            XCTAssertEqual(Set(keys).count, 3, "\(kind)")
        }
    }

    // MARK: ChannelSet lifetime

    func testChannelSetTakenOnlyOnce() {
        var mac = makeMac(pairKey, nonce: hostNonce)
        var phone = makePhone(pairKey, nonce: phoneNonce)
        XCTAssertNil(mac.takeChannelSet())
        XCTAssertNil(phone.takeChannelSet())
        guard case .send(let hello) = mac.begin(), case .send(let reply) = phone.receive(hello),
              case .authenticated(let auth, _) = mac.receive(reply), phone.receive(auth) == .authenticated
        else { return XCTFail("handshake") }
        XCTAssertNotNil(mac.takeChannelSet())
        XCTAssertNil(mac.takeChannelSet(), "the second take is refused")
        XCTAssertNotNil(phone.takeChannelSet())
        XCTAssertNil(phone.takeChannelSet())
    }

    func testSameSealerInstancePerKind() throws {
        let set = makeSet()
        XCTAssertTrue(set.sealer(.pointer) === set.sealer(.pointer))
        XCTAssertTrue(set.opener(.pointer) === set.opener(.pointer))
        #if DEBUG
        XCTAssertTrue(set.sealer(.measureP2M) === set.sealer(.measureP2M))
        XCTAssertFalse(set.sealer(.measureP2M) === set.sealer(.measureM2P))
        // A second measurement run (a new runner asking the same set for its sealer) goes on from the first run's counter.
        let receiver = makeSet().opener(.measureP2M)
        func counterOf(_ packet: Data) -> UInt64 { packet[1..<9].reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
        var counters: [UInt64] = []
        let firstRun = set.sealer(.measureP2M)
        for _ in 0..<5 {
            let packet = try firstRun.seal(plaintext(length: 16))
            counters.append(counterOf(packet))
            XCTAssertNoThrow(try receiver.open(packet).get())
        }
        XCTAssertEqual(counters, [1, 2, 3, 4, 5])
        let secondRun = set.sealer(.measureP2M)
        XCTAssertTrue(secondRun === firstRun)
        let next = try secondRun.seal(plaintext(length: 16))
        XCTAssertEqual(counterOf(next), 6, "N + 1, not 1 again")
        XCTAssertNoThrow(try receiver.open(next).get(), "and the receiver's window accepts it")
        #endif
    }

    // MARK: Counters

    func testCounterStrictlyIncreasesEvenWhenDiscarded() throws {
        let phone = makeSet(), mac = makeSet()
        let sealer = phone.sealer(.pointer)
        let opener = mac.opener(.pointer)
        var delivered: [UInt64] = []
        var all: [UInt64] = []
        for index in 1...1000 {
            let packet = try sealer.seal(plaintext(length: 16))
            let counter = packet[1..<9].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            all.append(counter)
            // 300 of them are never handed to the radio: their ciphertext is simply dropped.
            if index % 10 < 3 { continue }
            XCTAssertNoThrow(try opener.open(packet).get())
            delivered.append(counter)
        }
        XCTAssertEqual(all, Array(1...1000))
        XCTAssertEqual(delivered.count, 700)
        XCTAssertEqual(delivered, delivered.sorted())
        XCTAssertEqual(sealer.lastCounter, 1000)
    }

    func testCounterMaxThrows() throws {
        let set = ChannelSet(pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce, startingCounter: UInt64.max - 1)
        let sealer = set.sealer(.pointer)
        XCTAssertNoThrow(try sealer.seal(plaintext(length: 16)))
        XCTAssertEqual(sealer.lastCounter, UInt64.max)
        XCTAssertThrowsError(try sealer.seal(plaintext(length: 16))) { XCTAssertEqual($0 as? ChannelError, .counterExhausted) }
        XCTAssertEqual(sealer.lastCounter, UInt64.max)
    }

    // MARK: Replay

    func testOpenerRejectsReplay() throws {
        let phone = makeSet()
        let opener = makeSet().opener(.pointer)
        let packet = try phone.sealer(.pointer).seal(plaintext(length: 16))
        XCTAssertNoThrow(try opener.open(packet).get())
        XCTAssertEqual(opener.open(packet), .failure(.replayed))
    }

    func testOpenerAcceptsOutOfOrderWithin64() throws {
        let phone = makeSet()
        let opener = makeSet().opener(.pointer)
        let packets = try (1...70).map { _ in try phone.sealer(.pointer).seal(plaintext(length: 16)) }
        // Counter 70 first, then 6 (= 70 − 64, the oldest the window still holds), then 69, then the rest in reverse.
        XCTAssertNoThrow(try opener.open(packets[69]).get())
        XCTAssertNoThrow(try opener.open(packets[5]).get())
        XCTAssertNoThrow(try opener.open(packets[68]).get())
        XCTAssertEqual(opener.open(packets[5]), .failure(.replayed))
        for index in stride(from: 67, through: 6, by: -1) { XCTAssertNoThrow(try opener.open(packets[index]).get(), "\(index + 1)") }
    }

    func testOpenerRejectsOlderThan64() throws {
        let phone = makeSet()
        let opener = makeSet().opener(.pointer)
        let packets = try (1...70).map { _ in try phone.sealer(.pointer).seal(plaintext(length: 16)) }
        XCTAssertNoThrow(try opener.open(packets[69]).get())
        // Counter 5 is 65 below 70.
        XCTAssertEqual(opener.open(packets[4]), .failure(.tooOld))
    }

    func testWindowCommitOnlyAfterAuth() throws {
        let phone = makeSet()
        let opener = makeSet().opener(.pointer)
        let sealer = phone.sealer(.pointer)
        let first = try sealer.seal(plaintext(length: 16))
        let second = try sealer.seal(plaintext(length: 16))
        // A packet claiming counter 1,000,000 with a tag that does not verify must not move the window.
        var forged = Data([0x03]) + counterBytes(1_000_000) + plaintext(length: 16) + plaintext(length: 16)
        XCTAssertEqual(opener.open(forged), .failure(.authFailed))
        forged[1] = 0x7F
        XCTAssertEqual(opener.open(forged), .failure(.authFailed))
        XCTAssertNoThrow(try opener.open(first).get())
        XCTAssertNoThrow(try opener.open(second).get())
    }

    func testFramePacketsKeepTheirMagic() throws {
        // The first byte routes a notification; 0x02 stays the frame codec's.
        let frames = try FrameCodec.split(Data([1, 2, 3]), messageId: 0, maxFrameBytes: 182)
        XCTAssertEqual(frames[0][0], CounterChannel.frameMagic)
        XCTAssertNotEqual(CounterChannel.Kind.pointer.magic, CounterChannel.frameMagic)
    }
}
