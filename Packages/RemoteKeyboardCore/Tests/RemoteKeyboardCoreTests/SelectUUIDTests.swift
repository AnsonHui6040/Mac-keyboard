import XCTest
@testable import RemoteKeyboardCore

final class SelectUUIDTests: XCTestCase {
    func testSelectUUIDMatchesTheProtocolExample() {
        // docs/protocol/v4.md §1.3
        XCTAssertEqual(SelectUUID.make(hostId: Fixture.hostId).uuidString, "521F2AE3-477F-4EE0-9A40-14E35E4D35EE")
    }

    func testSelectUUIDIsDeterministicAndVersion4() {
        for seed in 0..<50 {
            let id = Data((0..<16).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ seed) })
            let a = SelectUUID.make(hostId: id)
            XCTAssertEqual(a, SelectUUID.make(hostId: id))
            XCTAssertEqual(a.uuid.6 >> 4, 4)
            XCTAssertEqual(a.uuid.8 >> 6, 2)
        }
    }

    func testSelectUUIDDiffersPerHost() {
        var seen = Set<UUID>()
        for seed in 0..<64 {
            seen.insert(SelectUUID.make(hostId: Data(repeating: UInt8(seed), count: 16)))
        }
        XCTAssertEqual(seen.count, 64)
        XCTAssertNotEqual(SelectUUID.make(hostId: Fixture.hostId), SelectUUID.make(hostId: Fixture.phoneId))
    }

    func testSelectUUIDNeverEqualsLinkOrPairingUUID() {
        let fixed = [
            GATTServiceSpec.Link.serviceUUID, GATTServiceSpec.Link.pairingAdvertUUID, GATTServiceSpec.serviceUUID
        ].compactMap(UUID.init(uuidString:))
        XCTAssertEqual(fixed.count, 3)
        XCTAssertEqual(GATTServiceSpec.Link.pairingAdvertUUID, "6BA36ECB-1BF9-49C1-B98D-37402247F356")
        for seed in 0..<256 {
            let uuid = SelectUUID.make(hostId: Data(repeating: UInt8(seed), count: 16))
            XCTAssertFalse(fixed.contains(uuid))
        }
    }

    func testGATTDatabaseIsUnchanged() {
        XCTAssertEqual(GATTServiceSpec.Link.serviceUUID, "706AA642-68A3-41FA-889D-24E30709B0D0")
        XCTAssertEqual(GATTServiceSpec.Link.eventUUID, "C7FC0313-53E7-4DCD-B75F-2AE66FE9C586")
        XCTAssertEqual(GATTServiceSpec.Link.controlUUID, "320468E2-53B6-4B6A-88EC-AE2752415818")
    }
}
