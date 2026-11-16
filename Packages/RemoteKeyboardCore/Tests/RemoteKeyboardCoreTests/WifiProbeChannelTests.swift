import CryptoKit
import XCTest
@testable import RemoteKeyboardCore

/// The Wi-Fi probe channel (docs/protocol/v4.md §8.6): host to phone, magic 0x05, 16 zero bytes of plaintext.
final class WifiProbeChannelTests: XCTestCase {
    private let pairKey = SymmetricKey(data: Data(repeating: 5, count: 32))
    private let hostNonce = Data(repeating: 1, count: 16)
    private let phoneNonce = Data(repeating: 2, count: 16)
    private let zeros = Data(repeating: 0, count: 16)

    private func makeSet(host: UInt8 = 1, phone: UInt8 = 2) -> ChannelSet {
        ChannelSet(pairKey: pairKey, hostNonce: Data(repeating: host, count: 16), phoneNonce: Data(repeating: phone, count: 16))
    }

    func testKindConstantsMatchTheSpec() {
        XCTAssertEqual(CounterChannel.Kind.wifiProbe.magic, 0x05)
        XCTAssertEqual(CounterChannel.Kind.wifiProbe.info, "rk-wfprobe-h2p")
        XCTAssertEqual(CounterChannel.Kind.wifiProbe.info.utf8.count, 14)
        XCTAssertEqual(CounterChannel.Kind.wifiProbe.noncePrefix, Array("WFP3".utf8))
        XCTAssertEqual(CounterChannel.Kind.wifiProbe.plaintextLengths, [16])
    }

    func testProbeRoundTripsFromHostToPhone() throws {
        let host = makeSet(), phone = makeSet()
        let packet = try host.sealer(.wifiProbe).seal(zeros)
        XCTAssertEqual(packet.count, 41)
        XCTAssertEqual(packet[0], 0x05)
        XCTAssertEqual(Array(packet[1..<9]), [0, 0, 0, 0, 0, 0, 0, 1], "the first probe carries counter 1")
        XCTAssertEqual(try phone.opener(.wifiProbe).open(packet).get(), zeros)
        XCTAssertEqual(phone.opener(.wifiProbe).lastOpenedCounter, 1)
    }

    func testReplayedProbeIsRejected() throws {
        let host = makeSet(), phone = makeSet()
        let packet = try host.sealer(.wifiProbe).seal(zeros)
        let opener = phone.opener(.wifiProbe)
        XCTAssertNoThrow(try opener.open(packet).get())
        XCTAssertEqual(opener.open(packet), .failure(.replayed), "the same datagram twice")
        XCTAssertEqual(opener.lastOpenedCounter, 1, "a replay does not move the window")
    }

    func testProbeKeyDiffersFromPointerKey() {
        let set = makeSet()
        XCTAssertNotEqual(set.keyDataForTesting(.wifiProbe), set.keyDataForTesting(.pointer))
        XCTAssertEqual(set.keyDataForTesting(.wifiProbe).count, 32)
    }

    func testProbeKeyFollowsTheDocumentedDerivation() {
        let expected = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: pairKey, salt: Data(), info: Data("rk-wfprobe-h2p".utf8) + hostNonce + phoneNonce, outputByteCount: 32)
        XCTAssertEqual(makeSet().keyDataForTesting(.wifiProbe), expected.withUnsafeBytes { Data($0) })
    }

    func testPointerPacketDoesNotOpenAsProbeAndTheOtherWayAround() throws {
        let set = makeSet()
        let pointer = try set.sealer(.pointer).seal(zeros)
        let probe = try set.sealer(.wifiProbe).seal(zeros)
        XCTAssertEqual(makeSet().opener(.wifiProbe).open(pointer), .failure(.badMagic))
        XCTAssertEqual(makeSet().opener(.pointer).open(probe), .failure(.badMagic))
        // Same bytes with the magic rewritten still fail: the keys differ.
        var relabelled = pointer
        relabelled[0] = 0x05
        XCTAssertEqual(makeSet().opener(.wifiProbe).open(relabelled), .failure(.authFailed))
    }

    func testProbeFromAnotherConnectionDoesNotOpen() throws {
        let packet = try makeSet(host: 9).sealer(.wifiProbe).seal(zeros)
        XCTAssertEqual(makeSet().opener(.wifiProbe).open(packet), .failure(.authFailed))
        let other = try makeSet(phone: 9).sealer(.wifiProbe).seal(zeros)
        XCTAssertEqual(makeSet().opener(.wifiProbe).open(other), .failure(.authFailed))
    }

    func testProbeOfTheWrongLengthIsRefused() throws {
        let packet = try makeSet().sealer(.wifiProbe).seal(zeros)
        let opener = makeSet().opener(.wifiProbe)
        XCTAssertEqual(opener.open(packet.dropLast()), .failure(.badLength))
        XCTAssertEqual(opener.open(packet + [0]), .failure(.badLength))
        XCTAssertThrowsError(try makeSet().sealer(.wifiProbe).seal(Data(repeating: 0, count: 15))) {
            XCTAssertEqual($0 as? ChannelError, .badLength)
        }
    }

    func testProbeCountersAreIndependentOfThePointerCounters() throws {
        let set = makeSet()
        _ = try set.sealer(.pointer).seal(zeros)
        _ = try set.sealer(.pointer).seal(zeros)
        let probe = try set.sealer(.wifiProbe).seal(zeros)
        XCTAssertEqual(Array(probe[1..<9]), [0, 0, 0, 0, 0, 0, 0, 1])
    }
}
