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
}
