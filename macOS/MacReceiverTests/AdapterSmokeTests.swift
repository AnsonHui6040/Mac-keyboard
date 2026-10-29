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

private final class FakeManager: PeripheralManaging {
    enum Call: Equatable { case add, removeAllServices, startAdvertising, stopAdvertising }
    var calls: [Call] = []
    func add(_ service: CBMutableService) { calls.append(.add) }
    func removeAllServices() { calls.append(.removeAllServices) }
    func startAdvertising(_ advertisementData: [String: Any]?) { calls.append(.startAdvertising) }
    func stopAdvertising() { calls.append(.stopAdvertising) }
}

@MainActor
final class GATTLifecycleTests: XCTestCase {
    private func make() -> (GATTPeripheralServer, FakeManager) {
        let fake = FakeManager()
        return (GATTPeripheralServer(makeManager: { _ in fake }), fake)
    }

    private func bringToAdvertising(_ server: GATTPeripheralServer) {
        server.handlePowerChange(.poweredOn)
        server.handleServiceAdded(error: nil)
        server.handleAdvertisingStarted(error: nil)
    }

    func testStopThenStartReaddsServiceBeforeAdvertising() {
        let (server, fake) = make()
        server.start()
        bringToAdvertising(server)
        XCTAssertEqual(server.state, .advertising)

        server.stop()
        fake.calls.removeAll()
        server.start()
        XCTAssertEqual(fake.calls, [.add])
        server.handleServiceAdded(error: nil)
        XCTAssertEqual(fake.calls, [.add, .startAdvertising])
        server.handleAdvertisingStarted(error: nil)
        XCTAssertEqual(server.state, .advertising)
    }

    func testLateServiceAddedAfterStopIsIgnored() {
        let (server, fake) = make()
        server.start()
        server.handlePowerChange(.poweredOn)
        server.stop()
        server.handleServiceAdded(error: nil)
        server.handleAdvertisingStarted(error: nil)
        XCTAssertEqual(server.state, .idle)

        fake.calls.removeAll()
        server.start()
        XCTAssertEqual(fake.calls, [.add])
    }

    func testPowerOffThenOnReaddsAndAdvertises() {
        let (server, fake) = make()
        server.start()
        bringToAdvertising(server)
        server.handlePowerChange(.poweredOff)
        XCTAssertEqual(server.state, .waitingForPower)

        fake.calls.removeAll()
        server.handlePowerChange(.poweredOn)
        XCTAssertEqual(fake.calls, [.add])
        server.handleServiceAdded(error: nil)
        server.handleAdvertisingStarted(error: nil)
        XCTAssertEqual(fake.calls, [.add, .startAdvertising])
        XCTAssertEqual(server.state, .advertising)
    }

    func testAdvertisingOnlyAfterServiceAdded() {
        let (server, fake) = make()
        server.start()
        server.handlePowerChange(.poweredOn)
        XCTAssertFalse(fake.calls.contains(.startAdvertising))
    }
}
