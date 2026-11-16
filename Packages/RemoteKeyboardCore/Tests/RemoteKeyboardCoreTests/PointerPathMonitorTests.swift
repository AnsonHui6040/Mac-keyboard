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

    // MARK: The send flow must be ready too

    func testLiveProbesWithoutAReadyFlowAreStillBluetooth() {
        var monitor = PointerPathMonitor()
        monitor.probeAccepted(atMicros: 10_000 * ms)
        XCTAssertEqual(monitor.path(atMicros: 10_100 * ms, targetReady: false), .bluetooth, "packets cannot leave yet")
        XCTAssertEqual(monitor.path(atMicros: 10_100 * ms, targetReady: true), .wifi)
    }

    func testAReadyFlowWithoutLiveProbesIsBluetooth() {
        var monitor = PointerPathMonitor()
        XCTAssertEqual(monitor.path(atMicros: 10_000 * ms, targetReady: true), .bluetooth, "no probe yet")
        monitor.probeAccepted(atMicros: 10_000 * ms)
        XCTAssertEqual(monitor.path(atMicros: 11_001 * ms, targetReady: true), .bluetooth, "probes ran out")
    }

    func testTheFlowBecomingReadyBringsWifiWithoutANewProbe() {
        var monitor = PointerPathMonitor()
        monitor.probeAccepted(atMicros: 10_000 * ms)
        XCTAssertEqual(monitor.path(atMicros: 10_050 * ms, targetReady: false), .bluetooth)
        XCTAssertEqual(monitor.path(atMicros: 10_200 * ms, targetReady: true), .wifi)
    }

    // MARK: Backing off after repeated failures

    /// Fails the path at `now`, then waits for the pause to run out and lets a probe bring Wi-Fi back.
    private func failAndRecover(_ monitor: inout PointerPathMonitor, failAt now: UInt64, expectedPause: UInt64) {
        monitor.sendFailed(atMicros: now)
        monitor.probeAccepted(atMicros: now + expectedPause - 1)
        XCTAssertEqual(monitor.path(atMicros: now + expectedPause - 1), .bluetooth, "still inside the pause of \(expectedPause / 1_000_000) s")
        monitor.probeAccepted(atMicros: now + expectedPause)
        XCTAssertEqual(monitor.path(atMicros: now + expectedPause), .wifi, "the pause is over")
    }

    func testThePauseDoublesWithEveryFailure() {
        var monitor = PointerPathMonitor(maxFailures: 10)
        monitor.probeAccepted(atMicros: 0)
        var now: UInt64 = 100 * ms
        for seconds: UInt64 in [5, 10, 20, 40] {
            failAndRecover(&monitor, failAt: now, expectedPause: seconds * 1_000_000)
            now += seconds * 1_000_000 + 100 * ms
        }
    }

    func testThePauseStopsGrowingAtTheCap() {
        var monitor = PointerPathMonitor(maxFailures: 10)
        monitor.probeAccepted(atMicros: 0)
        var now: UInt64 = 100 * ms
        for seconds: UInt64 in [5, 10, 20, 40, 60, 60, 60] {
            failAndRecover(&monitor, failAt: now, expectedPause: seconds * 1_000_000)
            now += seconds * 1_000_000 + 100 * ms
        }
    }

    func testTheThirdFailureEndsWifiForTheChannel() {
        var monitor = PointerPathMonitor()
        monitor.probeAccepted(atMicros: 0)
        var now: UInt64 = 100 * ms
        failAndRecover(&monitor, failAt: now, expectedPause: 5_000_000)
        now += 5_000_000 + 100 * ms
        failAndRecover(&monitor, failAt: now, expectedPause: 10_000_000)
        now += 10_000_000 + 100 * ms
        XCTAssertFalse(monitor.isWifiDisabled)
        monitor.sendFailed(atMicros: now)
        XCTAssertTrue(monitor.isWifiDisabled)
        for later in [now + 1_000_000, now + 120_000_000, now + 9_000_000_000] {
            monitor.probeAccepted(atMicros: later)
            XCTAssertEqual(monitor.path(atMicros: later), .bluetooth, "no probe counts once Wi-Fi is given up")
        }
    }

    func testResetStartsTheBackoffOver() {
        var monitor = PointerPathMonitor()
        monitor.probeAccepted(atMicros: 0)
        monitor.sendFailed(atMicros: 100 * ms)
        monitor.probeAccepted(atMicros: 5_200 * ms)
        monitor.sendFailed(atMicros: 5_300 * ms)
        monitor.probeAccepted(atMicros: 15_400 * ms)
        monitor.sendFailed(atMicros: 15_500 * ms)
        XCTAssertTrue(monitor.isWifiDisabled)
        monitor.reset()
        XCTAssertFalse(monitor.isWifiDisabled)
        monitor.probeAccepted(atMicros: 20_000 * ms)
        XCTAssertEqual(monitor.path(atMicros: 20_001 * ms), .wifi)
        monitor.sendFailed(atMicros: 20_100 * ms)
        monitor.probeAccepted(atMicros: 25_100 * ms)
        XCTAssertEqual(monitor.path(atMicros: 25_101 * ms), .wifi, "the first failure of the new channel pauses for 5 s again")
    }

    func testFailuresReportedInsideOnePauseCountOnce() {
        // Several sends in flight can all report the same broken flow.
        var monitor = PointerPathMonitor()
        monitor.probeAccepted(atMicros: 0)
        monitor.sendFailed(atMicros: 100 * ms)
        monitor.sendFailed(atMicros: 101 * ms)
        monitor.sendFailed(atMicros: 102 * ms)
        XCTAssertFalse(monitor.isWifiDisabled)
        monitor.probeAccepted(atMicros: 5_100 * ms)
        XCTAssertEqual(monitor.path(atMicros: 5_101 * ms), .wifi, "still the first 5 s pause, not 20")
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
