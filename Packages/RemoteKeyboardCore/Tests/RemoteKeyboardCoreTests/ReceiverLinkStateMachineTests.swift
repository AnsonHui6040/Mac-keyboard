import XCTest
@testable import RemoteKeyboardCore

private func scanningMachine() -> ReceiverLinkStateMachine {
    var m = ReceiverLinkStateMachine()
    _ = m.handle(.power(.poweredOn))
    _ = m.handle(.start)
    return m
}

private func connectingMachine(_ p: UUID) -> ReceiverLinkStateMachine {
    var m = scanningMachine()
    _ = m.handle(.discovered(p))
    return m
}

private func readyMachine(_ p: UUID) -> ReceiverLinkStateMachine {
    var m = connectingMachine(p)
    _ = m.handle(.connected(p))
    _ = m.handle(.linkReady(p))
    return m
}

final class ReceiverLinkStateMachineTests: XCTestCase {
    let p = UUID()

    func testStartPoweredOnScans() {
        var m = ReceiverLinkStateMachine(); _ = m.handle(.power(.poweredOn))
        XCTAssertEqual(m.handle(.start), [.startScan]); XCTAssertEqual(m.state, .scanning)
    }

    func testHappyPathToReady() {
        var m = scanningMachine()
        XCTAssertEqual(m.handle(.discovered(p)), [.stopScan, .connect(p), .startConnectTimeout(seconds: 5.0)])
        XCTAssertEqual(m.handle(.connected(p)), [.discover(p)])
        XCTAssertEqual(m.handle(.linkReady(p)), [.cancelConnectTimeout]); XCTAssertEqual(m.state, .ready(p))
    }

    func testDisconnectFromReadyRescans() {
        var m = readyMachine(p); XCTAssertEqual(m.handle(.disconnected(p)), [.startScan]); XCTAssertEqual(m.state, .scanning)
    }

    func testDisconnectOfOtherPeripheralIgnored() {
        var m = readyMachine(p); XCTAssertEqual(m.handle(.disconnected(UUID())), []); XCTAssertEqual(m.state, .ready(p))
    }

    func testConnectTimeoutCancelsAndRescans() {
        var m = connectingMachine(p); XCTAssertEqual(m.handle(.connectTimeout), [.cancel(p), .startScan]); XCTAssertEqual(m.state, .scanning)
    }

    func testServiceInvalidatedCancelsAndRescans() {
        var m = readyMachine(p); XCTAssertEqual(m.handle(.serviceInvalidated(p)), [.cancel(p), .startScan]); XCTAssertEqual(m.state, .scanning)
    }

    func testDiscoveredWhileConnectingIgnored() {
        var m = connectingMachine(p); XCTAssertEqual(m.handle(.discovered(UUID())), []); XCTAssertEqual(m.state, .connecting(p))
    }

    func testStopFromReadyCancels() {
        var m = readyMachine(p); XCTAssertEqual(m.handle(.stop), [.cancel(p)]); XCTAssertEqual(m.state, .idle)
    }

    func testPowerOffThenOnWhileStartedRescans() {
        var m = readyMachine(p); _ = m.handle(.power(.poweredOff)); XCTAssertEqual(m.state, .unavailable(.poweredOff))
        XCTAssertEqual(m.handle(.power(.poweredOn)), [.startScan])
    }

    func testStartBeforePowerScansOnPowerOn() {
        var m = ReceiverLinkStateMachine(); XCTAssertEqual(m.handle(.start), []); XCTAssertEqual(m.handle(.power(.poweredOn)), [.startScan])
    }

    func testStopWhileScanningStopsScan() {
        var m = scanningMachine(); XCTAssertEqual(m.handle(.stop), [.stopScan]); XCTAssertEqual(m.state, .idle)
    }

    func testStopWhileConnectingCancelsTimeoutAndPeripheral() {
        var m = connectingMachine(p); XCTAssertEqual(m.handle(.stop), [.cancelConnectTimeout, .cancel(p)])
    }

    func testStaleConnectTimeoutIgnoredWhenReady() {
        var m = readyMachine(p); XCTAssertEqual(m.handle(.connectTimeout), []); XCTAssertEqual(m.state, .ready(p))
    }

    func testDisconnectWhileDiscoveringCancelsTimeoutAndRescans() {
        var m = connectingMachine(p); _ = m.handle(.connected(p))
        XCTAssertEqual(m.handle(.disconnected(p)), [.cancelConnectTimeout, .startScan])
    }

    func testPowerOffWhileReadyCancelsPeripheral() {
        var m = readyMachine(p); XCTAssertEqual(m.handle(.power(.poweredOff)), [.cancel(p)])
    }

    func testPowerOnWhileIdleDoesNotScan() {
        var m = ReceiverLinkStateMachine(); XCTAssertEqual(m.handle(.power(.poweredOn)), []); XCTAssertEqual(m.state, .idle)
    }

    // MARK: T06 reconnect cycles

    func testTwentyDisconnectCyclesAlwaysRescan() {
        var m = scanningMachine()
        for _ in 0..<20 {
            _ = m.handle(.discovered(p)); _ = m.handle(.connected(p)); _ = m.handle(.linkReady(p))
            XCTAssertEqual(m.handle(.disconnected(p)), [.startScan])
            XCTAssertEqual(m.state, .scanning)
        }
    }

    func testLateDisconnectAfterRescanIgnored() {
        var m = readyMachine(p)
        _ = m.handle(.disconnected(p))
        XCTAssertEqual(m.handle(.disconnected(p)), [])
        XCTAssertEqual(m.state, .scanning)
    }

    // MARK: T06 rescan backoff

    func testBackoffScheduleIsImmediateThenGrowsAndCaps() {
        XCTAssertEqual((0...6).map(ReceiverLinkStateMachine.backoffSeconds(afterFailures:)), [0, 0, 0.5, 1, 2, 2, 2])
    }

    func testRepeatedHandshakeFailuresBackOffInsteadOfHotLooping() {
        var m = scanningMachine()
        _ = m.handle(.discovered(p))
        XCTAssertEqual(m.handle(.connectTimeout), [.cancel(p), .startScan], "the first failure rescans at once")
        _ = m.handle(.discovered(p))
        XCTAssertEqual(m.handle(.connectTimeout), [.cancel(p), .startScanAfter(seconds: 0.5)])
        XCTAssertEqual(m.state, .scanning)
        XCTAssertEqual(m.handle(.rescanTimer), [.startScan])
        _ = m.handle(.discovered(p))
        XCTAssertEqual(m.handle(.connectTimeout), [.cancel(p), .startScanAfter(seconds: 1)])
        _ = m.handle(.rescanTimer); _ = m.handle(.discovered(p))
        XCTAssertEqual(m.handle(.connectTimeout), [.cancel(p), .startScanAfter(seconds: 2)])
        _ = m.handle(.rescanTimer); _ = m.handle(.discovered(p))
        XCTAssertEqual(m.handle(.connectTimeout), [.cancel(p), .startScanAfter(seconds: 2)])
    }

    func testDisconnectAndInvalidationDuringHandshakeCountAsFailures() {
        var m = connectingMachine(p)
        XCTAssertEqual(m.handle(.disconnected(p)), [.cancelConnectTimeout, .startScan])
        _ = m.handle(.discovered(p)); _ = m.handle(.connected(p))
        XCTAssertEqual(m.handle(.serviceInvalidated(p)), [.cancelConnectTimeout, .cancel(p), .startScanAfter(seconds: 0.5)])
    }

    func testReadyResetsTheBackoff() {
        var m = scanningMachine()
        for _ in 0..<3 { _ = m.handle(.discovered(p)); _ = m.handle(.connectTimeout); _ = m.handle(.rescanTimer) }
        _ = m.handle(.discovered(p)); _ = m.handle(.connected(p)); _ = m.handle(.linkReady(p))
        XCTAssertEqual(m.handle(.disconnected(p)), [.startScan], "a drop after a good link rescans at once")
        _ = m.handle(.discovered(p))
        XCTAssertEqual(m.handle(.connectTimeout), [.cancel(p), .startScan], "failure count starts over")
    }

    func testNothingIsAcceptedWhileTheBackoffTimerIsPending() {
        var m = scanningMachine()
        for _ in 0..<2 { _ = m.handle(.discovered(p)); _ = m.handle(.connectTimeout) }
        XCTAssertEqual(m.handle(.discovered(UUID())), [])
        XCTAssertEqual(m.state, .scanning)
    }

    func testRescanTimerWithoutAPendingBackoffIsIgnored() {
        var m = scanningMachine()
        XCTAssertEqual(m.handle(.rescanTimer), [])
        var r = readyMachine(p)
        XCTAssertEqual(r.handle(.rescanTimer), [])
    }

    func testStopOrPowerLossCancelsAPendingBackoff() {
        func pending() -> ReceiverLinkStateMachine {
            var m = scanningMachine()
            for _ in 0..<2 { _ = m.handle(.discovered(p)); _ = m.handle(.connectTimeout) }
            return m
        }
        var stopped = pending()
        XCTAssertEqual(stopped.handle(.stop), [.cancelRescanTimer])
        XCTAssertEqual(stopped.state, .idle)
        var off = pending()
        XCTAssertEqual(off.handle(.power(.poweredOff)), [.cancelRescanTimer])
        XCTAssertEqual(off.handle(.power(.poweredOn)), [.startScan], "back on, the search resumes at once")
    }
}

final class ReceiverLinkReasonTests: XCTestCase {
    func testUnavailableStatesExplainWhy() {
        XCTAssertEqual(ReceiverLinkState.unavailable(.poweredOff).reasonText, "藍牙已關閉，請在 Mac 開啟藍牙")
        XCTAssertEqual(ReceiverLinkState.unavailable(.unauthorized).reasonText, "未授權藍牙，請到系統設定 › 隱私權與安全性 允許")
        XCTAssertEqual(ReceiverLinkState.unavailable(.unsupported).reasonText, "這台 Mac 不支援藍牙")
        XCTAssertNil(ReceiverLinkState.unavailable(.unknown).reasonText, "no reason before CoreBluetooth has reported")
    }

    func testOtherStatesHaveNoReason() {
        let id = UUID()
        for state in [ReceiverLinkState.idle, .scanning, .connecting(id), .discovering(id), .ready(id)] {
            XCTAssertNil(state.reasonText)
        }
    }
}

/// A clock the tests move by hand.
private final class ManualClock {
    var now = 1_000.0
}

/// Per-device holds: a notSelected, a handshake timeout or a version mismatch blocks only that device, and the search for
/// every other device goes on (docs/protocol/v4.md §6.4 and §10).
final class ReceiverLinkHoldTests: XCTestCase {
    let p = UUID()
    let q = UUID()

    private func ready(_ id: UUID, clock: ManualClock) -> ReceiverLinkStateMachine {
        var m = ReceiverLinkStateMachine(now: { clock.now })
        _ = m.handle(.power(.poweredOn))
        _ = m.handle(.start)
        _ = m.handle(.discovered(id))
        _ = m.handle(.connected(id))
        _ = m.handle(.linkReady(id))
        return m
    }

    func testConstants() {
        XCTAssertEqual(ReceiverLinkStateMachine.handshakeBackoffSeconds, 10.0)
        XCTAssertEqual(ReceiverLinkStateMachine.unsupportedVersionHoldSeconds, 60.0)
    }

    private func assertBacksOffWithoutSkipping(_ event: ReceiverLinkInput, file: StaticString = #filePath, line: UInt = #line) {
        let clock = ManualClock()
        var m = ready(p, clock: clock)
        let effects = m.handle(event)
        XCTAssertEqual(effects, [.cancel(p)], file: file, line: line)
        XCTAssertFalse(effects.contains { if case .startScanAfter = $0 { true } else { false } }, file: file, line: line)
        // The adapter reports the disconnect that the cancel causes; the search resumes at once, not after a backoff.
        XCTAssertEqual(m.handle(.disconnected(p)), [.startScan], file: file, line: line)
        XCTAssertEqual(m.state, .scanning, file: file, line: line)
        // The same device within 10 seconds: not connected, state unchanged.
        clock.now += 9.9
        XCTAssertEqual(m.handle(.discovered(p)), [], file: file, line: line)
        XCTAssertEqual(m.state, .scanning, file: file, line: line)
        // Another device is connected as usual.
        XCTAssertEqual(m.handle(.discovered(q)), [.stopScan, .connect(q), .startConnectTimeout(seconds: 5.0)], file: file, line: line)
    }

    func testHandshakeTimeoutBacksOffWithoutSkipping() { assertBacksOffWithoutSkipping(.handshakeTimeout(p)) }

    func testNotSelectedBacksOffWithoutSkipping() { assertBacksOffWithoutSkipping(.notSelected(p)) }

    func testBackoffEndsAfterTenSeconds() {
        let clock = ManualClock()
        var m = ready(p, clock: clock)
        _ = m.handle(.notSelected(p))
        _ = m.handle(.disconnected(p))
        clock.now += 10
        XCTAssertEqual(m.handle(.discovered(p)), [.stopScan, .connect(p), .startConnectTimeout(seconds: 5.0)])
    }

    func testUnsupportedVersionHoldsOnlyThatDeviceFor60Seconds() {
        let clock = ManualClock()
        var m = ready(p, clock: clock)
        XCTAssertEqual(m.handle(.unsupportedVersion(p)), [.cancel(p)])
        XCTAssertEqual(m.handle(.disconnected(p)), [.startScan])
        clock.now += 59.9
        XCTAssertEqual(m.handle(.discovered(p)), [])
        // The other device connects at once, and the held one is still held after it let go.
        XCTAssertEqual(m.handle(.discovered(q)), [.stopScan, .connect(q), .startConnectTimeout(seconds: 5.0)])
        _ = m.handle(.connectTimeout)
        _ = m.handle(.rescanTimer)
        XCTAssertEqual(m.handle(.discovered(p)), [])
        clock.now += 0.1
        XCTAssertEqual(m.handle(.discovered(p)), [.stopScan, .connect(p), .startConnectTimeout(seconds: 5.0)])
    }

    func testEventsForAnotherOrNoConnectionDoNothing() {
        let clock = ManualClock()
        var m = ready(p, clock: clock)
        for event in [ReceiverLinkInput.handshakeTimeout(q), .notSelected(q), .unsupportedVersion(q)] {
            XCTAssertEqual(m.handle(event), [])
            XCTAssertEqual(m.state, .ready(p))
        }
        // q was not held by those events.
        _ = m.handle(.disconnected(p))
        XCTAssertEqual(m.handle(.discovered(q)), [.stopScan, .connect(q), .startConnectTimeout(seconds: 5.0)])
        var scanning = ReceiverLinkStateMachine(now: { clock.now })
        _ = scanning.handle(.power(.poweredOn)); _ = scanning.handle(.start)
        XCTAssertEqual(scanning.handle(.notSelected(p)), [])
    }

    func testStopClearsTheHolds() {
        let clock = ManualClock()
        var m = ready(p, clock: clock)
        _ = m.handle(.unsupportedVersion(p))
        _ = m.handle(.stop)
        _ = m.handle(.start)
        XCTAssertEqual(m.handle(.discovered(p)), [.stopScan, .connect(p), .startConnectTimeout(seconds: 5.0)])
    }

    func testPlainDisconnectsAreNeverHeld() {
        let clock = ManualClock()
        var m = ready(p, clock: clock)
        _ = m.handle(.disconnected(p))
        XCTAssertEqual(m.handle(.discovered(p)), [.stopScan, .connect(p), .startConnectTimeout(seconds: 5.0)])
    }
}
