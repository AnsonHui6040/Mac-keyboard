import CoreBluetooth
import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

final class AdapterSmokeTests: XCTestCase {
    @MainActor
    func testServiceHasExpectedCharacteristicProperties() throws {
        let service = GATTPeripheralServer.makeService()
        XCTAssertEqual(service.uuid, CBUUID(string: GATTServiceSpec.serviceUUID))
        XCTAssertTrue(service.isPrimary)

        let characteristics = try XCTUnwrap(service.characteristics)
        func find(_ uuid: String) throws -> CBCharacteristic {
            try XCTUnwrap(characteristics.first { $0.uuid == CBUUID(string: uuid) })
        }
        let input = try find(GATTServiceSpec.inputUUID)
        let ack = try find(GATTServiceSpec.ackUUID)
        let status = try find(GATTServiceSpec.statusUUID)

        XCTAssertEqual(characteristics.count, 3)
        XCTAssertTrue(input.properties.contains(.write))
        XCTAssertTrue(ack.properties.contains(.notify))
        XCTAssertTrue(status.properties.contains(.read))
        XCTAssertTrue(status.properties.contains(.notify))
    }
}
