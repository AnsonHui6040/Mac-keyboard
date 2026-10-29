import XCTest
@testable import RemoteKeyboardCore

final class GATTServiceSpecTests: XCTestCase {
    func testUniqueUUIDs() {
        let all = [GATTServiceSpec.serviceUUID, GATTServiceSpec.inputUUID, GATTServiceSpec.ackUUID, GATTServiceSpec.statusUUID]
        XCTAssertEqual(Set(all).count, 4)
        all.forEach { XCTAssertNotNil(UUID(uuidString: $0)) }
    }
}
