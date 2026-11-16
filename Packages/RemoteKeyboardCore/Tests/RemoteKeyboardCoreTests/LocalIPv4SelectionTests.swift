import Foundation
import XCTest
@testable import RemoteKeyboardCore

/// Which of the iPhone's own addresses go into `pointerOpen.wifi` (spec §6.4): IPv4, up, broadcast-capable, not loopback,
/// valid for `WifiOffer`, at most four, no duplicates. The interface name is never looked at.
final class LocalIPv4SelectionTests: XCTestCase {
    private let wifiFlags = UInt32(IFF_UP | IFF_BROADCAST | IFF_RUNNING | IFF_MULTICAST)

    private func record(_ address: String, flags: UInt32? = nil, family: Int32 = AF_INET) -> InterfaceAddress {
        InterfaceAddress(flags: flags ?? wifiFlags, family: family, address: address)
    }

    func testAWifiAddressIsKept() {
        XCTAssertEqual(LocalIPv4Selection.pick(from: [record("192.168.1.23")]), ["192.168.1.23"])
    }

    func testNothingGivesNothing() {
        XCTAssertEqual(LocalIPv4Selection.pick(from: []), [])
    }

    func testLoopbackIsDropped() {
        let loopback = record("127.0.0.1", flags: UInt32(IFF_UP | IFF_LOOPBACK | IFF_RUNNING))
        XCTAssertEqual(LocalIPv4Selection.pick(from: [loopback, record("10.0.0.5")]), ["10.0.0.5"])
    }

    func testALoopbackFlagDropsAnyAddressOnThatInterface() {
        let odd = record("10.1.1.1", flags: UInt32(IFF_UP | IFF_BROADCAST | IFF_LOOPBACK))
        XCTAssertEqual(LocalIPv4Selection.pick(from: [odd]), [])
    }

    func testIPv6IsDropped() {
        XCTAssertEqual(LocalIPv4Selection.pick(from: [record("fe80::1", family: AF_INET6), record("10.0.0.5")]), ["10.0.0.5"])
    }

    func testAnInterfaceThatIsDownIsDropped() {
        let down = record("10.0.0.5", flags: UInt32(IFF_BROADCAST))
        XCTAssertEqual(LocalIPv4Selection.pick(from: [down]), [])
    }

    func testAPointToPointInterfaceWithoutBroadcastIsDropped() {
        // The cellular interface is up but has no broadcast capability.
        let cellular = record("10.77.3.9", flags: UInt32(IFF_UP | IFF_POINTOPOINT | IFF_RUNNING))
        XCTAssertEqual(LocalIPv4Selection.pick(from: [cellular, record("192.168.0.8")]), ["192.168.0.8"])
    }

    func testAddressesThatWifiOfferRejectsAreDropped() {
        let bad = ["0.0.0.0", "224.0.0.1", "255.255.255.255", "not an address", "300.1.1.1", "01.2.3.4", ""]
        XCTAssertEqual(LocalIPv4Selection.pick(from: bad.map { record($0) } + [record("172.16.4.2")]), ["172.16.4.2"])
    }

    func testDuplicatesCollapseToTheFirstOccurrence() {
        let all = [record("10.0.0.5"), record("192.168.1.9"), record("10.0.0.5")]
        XCTAssertEqual(LocalIPv4Selection.pick(from: all), ["10.0.0.5", "192.168.1.9"])
    }

    func testAtMostFourAndInTheOrderGiven() {
        let all = (1...7).map { record("10.0.0.\($0)") }
        XCTAssertEqual(LocalIPv4Selection.pick(from: all), ["10.0.0.1", "10.0.0.2", "10.0.0.3", "10.0.0.4"])
    }

    func testTheLimitIsTheOfferLimit() {
        XCTAssertEqual(LocalIPv4Selection.limit, WifiOffer.maxAddresses)
    }

    func testTheResultIsAcceptedByWifiOffer() throws {
        let picked = LocalIPv4Selection.pick(from: [record("192.168.1.23"), record("127.0.0.1"), record("10.0.0.2")])
        XCTAssertNotNil(WifiOffer(addrs: picked, port: 50_123))
    }

    func testOrderIsStableAcrossCalls() {
        let all = [record("192.168.1.9"), record("10.0.0.5")]
        XCTAssertEqual(LocalIPv4Selection.pick(from: all), LocalIPv4Selection.pick(from: all))
        XCTAssertEqual(LocalIPv4Selection.pick(from: all), ["192.168.1.9", "10.0.0.5"], "not sorted: the order the system gave")
    }
}
