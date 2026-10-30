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

    func testTheBoundCentralSubscribingAgainKeepsALockedHandshakeButRestartsAnUnlockedOne() {
        var binding = CentralBinding()
        _ = binding.subscribe(mac, locked: false)
        XCTAssertEqual(binding.subscribe(mac, locked: true), .keptExisting)
        XCTAssertEqual(binding.subscribe(mac, locked: false), .bound)
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
}
