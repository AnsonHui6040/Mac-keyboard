import XCTest
@testable import RemoteKeyboardCore

/// Where one cursor packet leaves (spec W5, §6.4): UDP does not depend on the Bluetooth radio, Bluetooth does.
final class PointerRouteTests: XCTestCase {
    func testWifiPathGoesOverUdpWhateverTheRadioIsDoing() {
        XCTAssertEqual(PointerRoute.choose(path: .wifi, radioBlocked: false), .udp)
        XCTAssertEqual(PointerRoute.choose(path: .wifi, radioBlocked: true), .udp, "a full radio must not hold up UDP")
    }

    func testBluetoothPathGoesOverTheRadioWhenItIsFree() {
        XCTAssertEqual(PointerRoute.choose(path: .bluetooth, radioBlocked: false), .bluetooth)
    }

    func testBluetoothPathWaitsWhileTheRadioIsFull() {
        XCTAssertEqual(PointerRoute.choose(path: .bluetooth, radioBlocked: true), .wait)
    }

    func testAFailedUdpSendFallsBackToTheRadioForThatPacket() {
        // The adapter marks the path down and chooses again: a free radio takes the packet, a full one makes it wait.
        var monitor = PointerPathMonitor()
        monitor.probeAccepted(atMicros: 1_000)
        XCTAssertEqual(PointerRoute.choose(path: monitor.path(atMicros: 2_000), radioBlocked: false), .udp)
        monitor.sendFailed(atMicros: 2_000)
        XCTAssertEqual(PointerRoute.choose(path: monitor.path(atMicros: 2_001), radioBlocked: false), .bluetooth)
        XCTAssertEqual(PointerRoute.choose(path: monitor.path(atMicros: 2_001), radioBlocked: true), .wait)
    }
}
