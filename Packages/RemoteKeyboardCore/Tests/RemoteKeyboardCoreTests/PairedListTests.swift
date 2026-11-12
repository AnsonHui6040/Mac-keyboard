import CryptoKit
import XCTest
@testable import RemoteKeyboardCore

final class PairedListTests: XCTestCase {
    private func host(_ n: UInt8, name: String? = nil) -> HostIdentity {
        HostIdentity(id: Data(repeating: n, count: 16), name: name ?? "host\(n)", platform: .mac)
    }

    private func phone(_ n: UInt8) -> PairedPhone {
        PairedPhone(
            identity: PhoneIdentity(id: Data(repeating: n, count: 16), name: "phone\(n)", platform: .ios),
            pairKey: SymmetricKey(data: Data(repeating: n, count: 32)))
    }

    func testCapacityIsEight() {
        XCTAssertEqual(PairedList<PairedPhone>.capacity, 8)
        XCTAssertEqual(PairedList<PairedHost>.capacity, 8)
    }

    func testAddOverwritesSameId() {
        var list = PairedList<PairedHost>()
        XCTAssertEqual(list.add(PairedHost(identity: host(1))), .added)
        XCTAssertEqual(list.add(PairedHost(identity: host(2))), .added)
        XCTAssertEqual(list.add(PairedHost(identity: host(1, name: "renamed"))), .replaced)
        XCTAssertEqual(list.entries.count, 2)
        XCTAssertEqual(list.entries.first?.identity.name, "renamed", "the entry keeps its place")

        var phones = PairedList<PairedPhone>()
        _ = phones.add(phone(1))
        let other = PairedPhone(identity: phone(1).identity, pairKey: SymmetricKey(data: Data(repeating: 99, count: 32)))
        XCTAssertEqual(phones.add(other), .replaced)
        XCTAssertEqual(phones.entries.count, 1)
        XCTAssertEqual(phones.entries[0].pairKey, other.pairKey)
    }

    func testAddBeyondEightIsRefused() {
        var list = PairedList<PairedPhone>()
        for n in 1...8 { XCTAssertEqual(list.add(phone(UInt8(n))), .added) }
        XCTAssertEqual(list.add(phone(9)), .full)
        XCTAssertEqual(list.entries.count, 8)
        XCTAssertNil(list.entries.first { $0.identity.id == phone(9).identity.id })
        // A known id is still replaceable when the list is full.
        XCTAssertEqual(list.add(phone(3)), .replaced)
        XCTAssertTrue(list.remove(id: phone(2).identity.id))
        XCTAssertEqual(list.add(phone(9)), .added)
        XCTAssertFalse(list.remove(id: Data(repeating: 77, count: 16)))
    }

    func testRemoveSelectedPicksNextOrNone() {
        var selection = HostSelection()
        for n in 1...3 { XCTAssertEqual(selection.add(host(UInt8(n))), .added) }
        XCTAssertEqual(selection.selectedId, host(1).id, "the first host added is the current one")
        XCTAssertTrue(selection.select(id: host(2).id))
        XCTAssertEqual(selection.selectedId, host(2).id)
        // Removing a host that is not selected leaves the selection alone.
        selection.remove(id: host(1).id)
        XCTAssertEqual(selection.selectedId, host(2).id)
        XCTAssertEqual(selection.hosts.map(\.id), [host(2).id, host(3).id])
        // Removing the selected host picks the next one in the list.
        selection.remove(id: host(2).id)
        XCTAssertEqual(selection.selectedId, host(3).id)
        // The last one standing, then none.
        selection.remove(id: host(3).id)
        XCTAssertNil(selection.selectedId)
        XCTAssertTrue(selection.hosts.isEmpty)
    }

    func testRemovingTheSelectedLastHostWrapsToTheFirst() {
        var selection = HostSelection()
        for n in 1...3 { _ = selection.add(host(UInt8(n))) }
        XCTAssertTrue(selection.select(id: host(3).id))
        selection.remove(id: host(3).id)
        XCTAssertEqual(selection.selectedId, host(1).id)
    }

    func testSelectUnknownIdIsRefused() {
        var selection = HostSelection()
        _ = selection.add(host(1))
        XCTAssertFalse(selection.select(id: host(9).id))
        XCTAssertEqual(selection.selectedId, host(1).id)
    }

    func testCycleWrapsAround() {
        var selection = HostSelection()
        for n in 1...3 { _ = selection.add(host(UInt8(n))) }
        XCTAssertEqual(selection.cycle()?.id, host(2).id)
        XCTAssertEqual(selection.cycle()?.id, host(3).id)
        XCTAssertEqual(selection.cycle()?.id, host(1).id)
        XCTAssertEqual(selection.selectedId, host(1).id)
    }

    func testCycleWithOneHostReturnsNil() {
        var selection = HostSelection()
        XCTAssertNil(selection.cycle(), "no host at all")
        _ = selection.add(host(1))
        XCTAssertNil(selection.cycle())
        XCTAssertEqual(selection.selectedId, host(1).id)
    }

    func testHostSelectionHoldsAtMostEightAndReplacesKnownIds() {
        var selection = HostSelection()
        for n in 1...8 { XCTAssertEqual(selection.add(host(UInt8(n))), .added) }
        XCTAssertEqual(selection.add(host(9)), .full)
        XCTAssertEqual(selection.add(host(4, name: "again")), .replaced)
        XCTAssertEqual(selection.hosts.count, 8)
        XCTAssertEqual(selection.hosts[3].name, "again")
    }

    func testHostSelectionSurvivesALocalStorageRoundTrip() throws {
        var selection = HostSelection()
        for n in 1...3 { _ = selection.add(host(UInt8(n))) }
        _ = selection.select(id: host(2).id)
        let back = try JSONDecoder().decode(HostSelection.self, from: JSONEncoder().encode(selection))
        XCTAssertEqual(back, selection)
    }
}
