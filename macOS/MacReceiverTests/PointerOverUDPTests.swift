import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

/// A `0x03` packet that reaches the Receiver over the local network (Wi-Fi assist, spec W9, W10) goes through the same checks and
/// the same replay window as one that came over Bluetooth. Only the count of failures in a row differs: anybody on the local
/// network can send datagrams, and none of them may close the channel or spend a grant.
@MainActor
final class PointerOverUDPTests: XCTestCase {
    private func clicks(_ r: PointerRig) -> Int {
        r.output.actions.filter { if case .click = $0 { true } else { false } }.count
    }

    /// A packet the phone sealed, as a pair: the bytes as they were sent and a copy with a flipped tag bit.
    private func sealedClick(_ r: PointerRig) throws -> (good: Data, forged: Data) {
        let good = try r.phone.sealer(.pointer).seal(r.click().encode())
        var forged = good
        forged[forged.count - 1] ^= 0x01
        return (good, forged)
    }

    func testAPacketOverUDPDoesWhatTheSamePacketOverBluetoothDoes() throws {
        let r = PointerRig()
        r.openChannel()
        r.receiver.handle(try sealedClick(r).good, via: .udp)
        XCTAssertEqual(clicks(r), 1)
        r.receiver.handle(try sealedClick(r).good, via: .ble)
        XCTAssertEqual(clicks(r), 2)
    }

    func testTwentyBadPacketsOverUDPNeverRenewTheGrantOrCloseTheChannel() throws {
        let r = PointerRig()
        r.openChannel()
        let grant = r.receiver.grant
        for _ in 0..<20 { r.receiver.handle(try sealedClick(r).forged, via: .udp) }
        XCTAssertEqual(r.grantChanges, 0, "no new grant: the phone is not told to open again")
        XCTAssertEqual(r.receiver.grant, grant)
        XCTAssertTrue(r.receiver.isOpen)
        r.receiver.handle(try sealedClick(r).good, via: .udp)
        XCTAssertEqual(clicks(r), 1, "the channel still works afterwards")
    }

    func testEightBadPacketsOverBluetoothStillRenewTheGrant() throws {
        let r = PointerRig()
        r.openChannel()
        let grant = r.receiver.grant
        for _ in 0..<8 { r.receiver.handle(try sealedClick(r).forged, via: .ble) }
        XCTAssertEqual(r.grantChanges, 1)
        XCTAssertNotEqual(r.receiver.grant, grant)
        XCTAssertFalse(r.receiver.isOpen)
    }

    func testUDPFailuresDoNotAddToABluetoothStreakAndAGoodUDPPacketDoesNotEndIt() throws {
        let r = PointerRig()
        r.openChannel()
        for _ in 0..<7 { r.receiver.handle(try sealedClick(r).forged, via: .ble) }
        for _ in 0..<5 { r.receiver.handle(try sealedClick(r).forged, via: .udp) }
        XCTAssertEqual(r.grantChanges, 0, "bad packets over UDP do not extend the streak")
        r.receiver.handle(try sealedClick(r).good, via: .udp)
        XCTAssertEqual(r.grantChanges, 0)
        XCTAssertTrue(r.receiver.isOpen)
        r.receiver.handle(try sealedClick(r).forged, via: .ble)
        XCTAssertEqual(r.grantChanges, 1, "a good packet over UDP did not reset the seven: the eighth over Bluetooth renews")
    }

    func testAGoodPacketOverBluetoothStillEndsTheStreak() throws {
        let r = PointerRig()
        r.openChannel()
        for _ in 0..<7 { r.receiver.handle(try sealedClick(r).forged, via: .ble) }
        r.receiver.handle(try sealedClick(r).good, via: .ble)
        r.receiver.handle(try sealedClick(r).forged, via: .ble)
        XCTAssertEqual(r.grantChanges, 0)
        XCTAssertTrue(r.receiver.isOpen)
    }

    func testAPacketSeenOverBluetoothIsAReplayOverUDPAndTheOtherWayRound() throws {
        let r = PointerRig()
        r.openChannel()
        let first = try sealedClick(r).good
        r.receiver.handle(first, via: .ble)
        r.receiver.handle(first, via: .udp)
        XCTAssertEqual(clicks(r), 1, "the same bytes over UDP are a replay: one shared window")

        let second = try sealedClick(r).good
        r.receiver.handle(second, via: .udp)
        r.receiver.handle(second, via: .ble)
        XCTAssertEqual(clicks(r), 2)
    }

    func testTheClosingLineCountsPacketsPerTransportAndNeverMentionsContent() throws {
        let r = PointerRig()
        r.openChannel()
        for _ in 0..<2 { r.receiver.handle(try sealedClick(r).good, via: .ble) }
        for _ in 0..<3 { r.receiver.handle(try sealedClick(r).good, via: .udp) }
        _ = r.receiver.handleClose()
        let line = try XCTUnwrap(r.logLines.last { $0.hasPrefix("pointer closed") })
        XCTAssertTrue(line.contains("packets=5"), line)
        XCTAssertTrue(line.contains("udp=3"), line)
    }

    func testBadPacketsOverUDPAreNotWrittenToTheLogOneByOne() throws {
        let r = PointerRig()
        r.openChannel()
        let before = r.logLines.count
        for _ in 0..<20 { r.receiver.handle(try sealedClick(r).forged, via: .udp) }
        XCTAssertEqual(r.logLines.count, before, "a stranger on the network must not be able to fill the log")
    }
}
