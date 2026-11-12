import XCTest
@testable import RemoteKeyboardCore

final class CentralBindingTests: XCTestCase {
    private let mac = UUID()
    private let stranger = UUID()

    func testFirstSubscriberIsBound() {
        var binding = CentralBinding()
        XCTAssertEqual(binding.subscribe(mac, locked: false), .bound)
        XCTAssertEqual(binding.subscribed, mac)
    }

    func testOnlyTheBoundCentralMayWrite() {
        var binding = CentralBinding()
        XCTAssertFalse(binding.shouldAcceptWrite(from: mac), "nobody is bound yet")
        _ = binding.subscribe(mac, locked: false)
        XCTAssertTrue(binding.shouldAcceptWrite(from: mac))
        XCTAssertFalse(binding.shouldAcceptWrite(from: stranger))
    }

    func testAnotherCentralCannotReplaceALockedConnection() {
        var binding = CentralBinding()
        _ = binding.subscribe(mac, locked: false)
        XCTAssertEqual(binding.subscribe(stranger, locked: true), .refused)
        XCTAssertEqual(binding.subscribed, mac, "the bound central stays")
        XCTAssertTrue(binding.shouldAcceptWrite(from: mac))
        XCTAssertFalse(binding.shouldAcceptWrite(from: stranger))
    }

    func testAnotherCentralReplacesAnUnlockedConnection() {
        var binding = CentralBinding()
        _ = binding.subscribe(mac, locked: false)
        XCTAssertEqual(binding.subscribe(stranger, locked: false), .bound)
        XCTAssertEqual(binding.subscribed, stranger)
    }

    func testResubscribeFromBoundCentralRebindsFresh() {
        var binding = CentralBinding()
        _ = binding.subscribe(mac, locked: false)
        // A new subscription is a new connection on the Mac side, so a locked (authenticated) handshake of the old one can
        // never be valid again: the bound central re-subscribing always starts fresh.
        XCTAssertEqual(binding.subscribe(mac, locked: true), .bound)
        XCTAssertEqual(binding.subscribe(mac, locked: false), .bound)
        XCTAssertEqual(binding.subscribed, mac)
    }

    func testOnlyADifferentCentralIsRefusedWhileLocked() {
        var binding = CentralBinding()
        _ = binding.subscribe(mac, locked: true)
        XCTAssertEqual(binding.subscribe(stranger, locked: true), .refused)
        XCTAssertEqual(binding.subscribe(mac, locked: true), .bound)
    }

    func testPowerLossClearsTheBinding() {
        for power: PeripheralPower in [.poweredOff, .unauthorized, .unsupported, .unknown] {
            var binding = CentralBinding()
            _ = binding.subscribe(mac, locked: true)
            binding.powerChanged(power)
            XCTAssertNil(binding.subscribed, "\(power)")
            XCTAssertFalse(binding.shouldAcceptWrite(from: mac))
            // After power returns even a central with another identifier can bind: the old connection is gone.
            XCTAssertEqual(binding.subscribe(stranger, locked: true), .bound)
        }
    }

    func testPoweredOnKeepsTheBinding() {
        var binding = CentralBinding()
        _ = binding.subscribe(mac, locked: true)
        binding.powerChanged(.poweredOn)
        XCTAssertEqual(binding.subscribed, mac)
    }

    func testUnsubscribeOfAnotherCentralChangesNothing() {
        var binding = CentralBinding()
        _ = binding.subscribe(mac, locked: false)
        XCTAssertFalse(binding.unsubscribe(stranger))
        XCTAssertEqual(binding.subscribed, mac)
        XCTAssertTrue(binding.unsubscribe(mac))
        XCTAssertNil(binding.subscribed)
        XCTAssertEqual(binding.subscribe(stranger, locked: true), .bound, "an empty binding takes any first subscriber")
    }

    func testClearReleasesTheBinding() {
        var binding = CentralBinding()
        _ = binding.subscribe(mac, locked: true)
        binding.clear()
        XCTAssertNil(binding.subscribed)
        XCTAssertFalse(binding.shouldAcceptWrite(from: mac))
    }

    // MARK: hello routing (docs/protocol/v4.md §6.3)

    func testMatchingHelloFromTheBoundCentralStartsTheHandshake() {
        var binding = CentralBinding()
        _ = binding.subscribe(mac, locked: false)
        XCTAssertEqual(binding.helloDisposition(from: mac, hostIdMatches: true, locked: false), .handshake)
        XCTAssertEqual(binding.subscribed, mac)
        XCTAssertEqual(binding.helloDisposition(from: mac, hostIdMatches: true, locked: true), .handshake, "the bound one is never refused")
        XCTAssertEqual(binding.subscribed, mac)
    }

    func testMatchingHelloFromOtherCentralIsIgnoredWhenLocked() {
        var binding = CentralBinding()
        _ = binding.subscribe(mac, locked: true)
        XCTAssertEqual(binding.helloDisposition(from: stranger, hostIdMatches: true, locked: true), .ignore)
        XCTAssertEqual(binding.subscribed, mac, "the binding does not change")
    }

    func testMatchingHelloFromOtherCentralTakesOverWhenNotLocked() {
        var binding = CentralBinding()
        _ = binding.subscribe(mac, locked: false)
        XCTAssertEqual(binding.helloDisposition(from: stranger, hostIdMatches: true, locked: false), .handshake)
        XCTAssertEqual(binding.subscribed, stranger)
        XCTAssertTrue(binding.shouldAcceptWrite(from: stranger))
        XCTAssertFalse(binding.shouldAcceptWrite(from: mac))
    }

    func testNotSelectedDoesNotDisturbAuthenticatedCentral() {
        var binding = CentralBinding()
        _ = binding.subscribe(mac, locked: true)
        XCTAssertEqual(binding.helloDisposition(from: stranger, hostIdMatches: false, locked: true), .replyNotSelected)
        XCTAssertEqual(binding.subscribed, mac)
        XCTAssertTrue(binding.shouldAcceptWrite(from: mac))
        XCTAssertFalse(binding.shouldAcceptWrite(from: stranger))
    }

    func testMismatchedHelloFromAnotherCentralKeepsAnUnlockedBindingToo() {
        var binding = CentralBinding()
        _ = binding.subscribe(mac, locked: false)
        XCTAssertEqual(binding.helloDisposition(from: stranger, hostIdMatches: false, locked: false), .replyNotSelected)
        XCTAssertEqual(binding.subscribed, mac)
    }

    func testHelloFromBoundCentralWithWrongHostReleasesBinding() {
        var binding = CentralBinding()
        _ = binding.subscribe(mac, locked: false)
        XCTAssertEqual(binding.helloDisposition(from: mac, hostIdMatches: false, locked: false), .replyNotSelected)
        XCTAssertNil(binding.subscribed)
        XCTAssertFalse(binding.shouldAcceptWrite(from: mac))
        // Even a locked binding is released when its own central says it meant another host.
        _ = binding.subscribe(mac, locked: false)
        XCTAssertEqual(binding.helloDisposition(from: mac, hostIdMatches: false, locked: true), .replyNotSelected)
        XCTAssertNil(binding.subscribed)
    }

    func testMalformedHelloIsIgnoredFromOthersAndGoesToTheHandshakeFromTheBoundCentral() {
        let good = Data(repeating: 1, count: 16)
        let bad = Data(repeating: 1, count: 15)
        var binding = CentralBinding()
        _ = binding.subscribe(mac, locked: false)
        let badId = ControlMessage.hello(hostId: bad, hostNonce: good)
        let badNonce = ControlMessage.hello(hostId: good, hostNonce: bad)
        for message in [badId, badNonce] {
            XCTAssertEqual(binding.helloDisposition(from: stranger, hello: message, currentHostId: good, locked: false), .ignore)
            XCTAssertEqual(binding.subscribed, mac, "no replacement, no notSelected")
            XCTAssertEqual(binding.helloDisposition(from: mac, hello: message, currentHostId: good, locked: false), .handshake)
            XCTAssertEqual(binding.subscribed, mac)
        }
        // A well-formed hello goes through the same function.
        XCTAssertEqual(
            binding.helloDisposition(from: stranger, hello: .hello(hostId: Data(repeating: 9, count: 16), hostNonce: good), currentHostId: good, locked: true),
            .replyNotSelected)
        XCTAssertEqual(
            binding.helloDisposition(from: mac, hello: .hello(hostId: good, hostNonce: good), currentHostId: good, locked: false), .handshake)
        XCTAssertEqual(
            binding.helloDisposition(from: mac, hello: .hello(hostId: good, hostNonce: good), currentHostId: nil, locked: false), .replyNotSelected,
            "no current host")
        // Anything that is not a hello is not this function's business.
        XCTAssertEqual(binding.helloDisposition(from: stranger, hello: .authFailed, currentHostId: good, locked: false), .ignore)
    }
}
