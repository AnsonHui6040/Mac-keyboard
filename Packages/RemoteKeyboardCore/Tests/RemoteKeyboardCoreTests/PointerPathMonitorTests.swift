import CryptoKit
import XCTest
@testable import RemoteKeyboardCore

/// Whether the cursor packets go over Wi-Fi or Bluetooth right now (spec W5, W7; docs/protocol/v4.md §8.6 rule 2).
final class PointerPathMonitorTests: XCTestCase {
    private let ms: UInt64 = 1_000

    func testWithoutAProbeThePathIsBluetooth() {
        let monitor = PointerPathMonitor()
        XCTAssertEqual(monitor.path(atMicros: 0), .bluetooth)
        XCTAssertEqual(monitor.path(atMicros: 5_000_000), .bluetooth)
    }

    func testAnAcceptedProbeMakesTheNextSecondWifi() {
        var monitor = PointerPathMonitor()
        monitor.probeAccepted(atMicros: 10_000 * ms)
        XCTAssertEqual(monitor.path(atMicros: 10_000 * ms), .wifi)
        XCTAssertEqual(monitor.path(atMicros: 10_999 * ms), .wifi)
        XCTAssertEqual(monitor.path(atMicros: 11_000 * ms), .wifi, "1000 ms after the probe still counts")
    }

    func testAfterTheWindowThePathIsBluetoothAgain() {
        var monitor = PointerPathMonitor()
        monitor.probeAccepted(atMicros: 10_000 * ms)
        XCTAssertEqual(monitor.path(atMicros: 11_001 * ms), .bluetooth)
        XCTAssertEqual(monitor.path(atMicros: 60_000 * ms), .bluetooth)
    }

    func testALaterProbeExtendsTheWindow() {
        var monitor = PointerPathMonitor()
        monitor.probeAccepted(atMicros: 10_000 * ms)
        monitor.probeAccepted(atMicros: 10_900 * ms)
        XCTAssertEqual(monitor.path(atMicros: 11_800 * ms), .wifi)
        XCTAssertEqual(monitor.path(atMicros: 11_901 * ms), .bluetooth)
    }

    func testResetGoesBackToBluetoothAtOnce() {
        var monitor = PointerPathMonitor()
        monitor.probeAccepted(atMicros: 10_000 * ms)
        monitor.reset()
        XCTAssertEqual(monitor.path(atMicros: 10_001 * ms), .bluetooth)
    }

    func testAProbeAfterResetBringsWifiBack() {
        var monitor = PointerPathMonitor()
        monitor.probeAccepted(atMicros: 10_000 * ms)
        monitor.reset()
        monitor.probeAccepted(atMicros: 10_100 * ms)
        XCTAssertEqual(monitor.path(atMicros: 10_200 * ms), .wifi)
    }

    func testTheWindowIsConfigurable() {
        var monitor = PointerPathMonitor(liveWindowMicros: 300 * ms)
        monitor.probeAccepted(atMicros: 1_000 * ms)
        XCTAssertEqual(monitor.path(atMicros: 1_300 * ms), .wifi)
        XCTAssertEqual(monitor.path(atMicros: 1_301 * ms), .bluetooth)
    }

    func testAClockThatStepsBackDoesNotWrapAround() {
        var monitor = PointerPathMonitor()
        monitor.probeAccepted(atMicros: 10_000 * ms)
        XCTAssertEqual(monitor.path(atMicros: 9_000 * ms), .wifi)
    }

    // MARK: A send that failed

    func testAFailedSendDropsTheWifiPathAtOnce() {
        var monitor = PointerPathMonitor()
        monitor.probeAccepted(atMicros: 10_000 * ms)
        monitor.sendFailed(atMicros: 10_100 * ms)
        XCTAssertEqual(monitor.path(atMicros: 10_101 * ms), .bluetooth)
    }

    func testProbesRightAfterAFailedSendDoNotBringWifiBack() {
        // Local network permission denied: probes still arrive (receiving needs no permission) but every send fails.
        var monitor = PointerPathMonitor()
        monitor.probeAccepted(atMicros: 10_000 * ms)
        monitor.sendFailed(atMicros: 10_100 * ms)
        monitor.probeAccepted(atMicros: 10_350 * ms)
        monitor.probeAccepted(atMicros: 11_000 * ms)
        XCTAssertEqual(monitor.path(atMicros: 11_001 * ms), .bluetooth, "the pause after a failure has not run out")
    }

    func testAfterThePauseAProbeBringsWifiBack() {
        var monitor = PointerPathMonitor(liveWindowMicros: 1_000 * ms, failureHoldoffMicros: 5_000 * ms)
        monitor.probeAccepted(atMicros: 10_000 * ms)
        monitor.sendFailed(atMicros: 10_100 * ms)
        monitor.probeAccepted(atMicros: 15_100 * ms)
        XCTAssertEqual(monitor.path(atMicros: 15_200 * ms), .wifi)
    }

    func testResetEndsThePauseToo() {
        // A new channel (new pointerOpen) starts clean.
        var monitor = PointerPathMonitor()
        monitor.sendFailed(atMicros: 10_000 * ms)
        monitor.reset()
        monitor.probeAccepted(atMicros: 10_100 * ms)
        XCTAssertEqual(monitor.path(atMicros: 10_200 * ms), .wifi)
    }
}

/// A probe only counts when it opens (spec W6; Review Focus 5): a forged, mangled or replayed datagram never extends the path.
final class PointerPathProbeTests: XCTestCase {
    private let pairKey = SymmetricKey(data: Data(repeating: 5, count: 32))
    private let zeros = Data(repeating: 0, count: 16)

    private func makeSet() -> ChannelSet {
        ChannelSet(pairKey: pairKey, hostNonce: Data(repeating: 1, count: 16), phoneNonce: Data(repeating: 2, count: 16))
    }

    func testAValidProbeIsAcceptedAndMakesWifi() throws {
        let host = makeSet(), phone = makeSet()
        let packet = try host.sealer(.wifiProbe).seal(zeros)
        var monitor = PointerPathMonitor()
        XCTAssertTrue(monitor.handleProbe(packet, opener: phone.opener(.wifiProbe), atMicros: 5_000))
        XCTAssertEqual(monitor.path(atMicros: 5_001), .wifi)
    }

    func testAReplayedProbeDoesNotExtendTheWindow() throws {
        let host = makeSet(), phone = makeSet()
        let packet = try host.sealer(.wifiProbe).seal(zeros)
        let opener = phone.opener(.wifiProbe)
        var monitor = PointerPathMonitor()
        XCTAssertTrue(monitor.handleProbe(packet, opener: opener, atMicros: 1_000_000))
        XCTAssertFalse(monitor.handleProbe(packet, opener: opener, atMicros: 1_900_000), "the same datagram a second time")
        XCTAssertEqual(monitor.path(atMicros: 2_000_000), .wifi)
        XCTAssertEqual(monitor.path(atMicros: 2_000_001), .bluetooth, "the replay at 1.9 s moved nothing")
    }

    func testAForgedProbeDoesNothing() throws {
        let phone = makeSet()
        let stranger = ChannelSet(
            pairKey: SymmetricKey(data: Data(repeating: 9, count: 32)),
            hostNonce: Data(repeating: 1, count: 16), phoneNonce: Data(repeating: 2, count: 16))
        let forged = try stranger.sealer(.wifiProbe).seal(zeros)
        var monitor = PointerPathMonitor()
        XCTAssertFalse(monitor.handleProbe(forged, opener: phone.opener(.wifiProbe), atMicros: 1_000))
        XCTAssertEqual(monitor.path(atMicros: 1_001), .bluetooth)
    }

    func testGarbageAndAPointerPacketDoNothing() throws {
        let host = makeSet(), phone = makeSet()
        var monitor = PointerPathMonitor()
        let opener = phone.opener(.wifiProbe)
        XCTAssertFalse(monitor.handleProbe(Data([1, 2, 3]), opener: opener, atMicros: 1_000))
        XCTAssertFalse(monitor.handleProbe(Data(), opener: opener, atMicros: 1_000))
        let pointer = try host.sealer(.pointer).seal(zeros)
        XCTAssertFalse(monitor.handleProbe(pointer, opener: opener, atMicros: 1_000), "a 0x03 packet is not a probe")
        XCTAssertEqual(monitor.path(atMicros: 1_001), .bluetooth)
    }

    func testAProbeDuringThePauseOpensButDoesNotCount() throws {
        let host = makeSet(), phone = makeSet()
        var monitor = PointerPathMonitor()
        monitor.sendFailed(atMicros: 1_000)
        let packet = try host.sealer(.wifiProbe).seal(zeros)
        XCTAssertFalse(monitor.handleProbe(packet, opener: phone.opener(.wifiProbe), atMicros: 2_000))
        XCTAssertEqual(monitor.path(atMicros: 2_001), .bluetooth)
    }

    /// Review Focus 2: when the path lapses the next packet is sealed with the next counter, never an old one.
    func testCountersKeepRisingAcrossAPathChange() throws {
        let host = makeSet()
        let pointer = host.sealer(.pointer)
        var monitor = PointerPathMonitor()
        monitor.probeAccepted(atMicros: 0)
        var counters: [UInt64] = []
        for now in stride(from: UInt64(0), through: 3_000_000, by: 500_000) {
            _ = monitor.path(atMicros: now)  // the route is chosen, then the packet sealed, whichever path it is
            _ = try pointer.seal(zeros)
            counters.append(pointer.lastCounter)
        }
        XCTAssertEqual(counters, Array(1...7))
    }
}
