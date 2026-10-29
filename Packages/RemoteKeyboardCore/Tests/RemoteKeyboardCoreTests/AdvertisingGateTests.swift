import XCTest
@testable import RemoteKeyboardCore

final class AdvertisingGateTests: XCTestCase {
    func testAdvertiseWaitsForPoweredOnAndServiceReady() {
        XCTAssertFalse(AdvertisingGate.shouldAdvertise(power: .poweredOff, serviceAdded: true))
        XCTAssertFalse(AdvertisingGate.shouldAdvertise(power: .poweredOn, serviceAdded: false))
        XCTAssertFalse(AdvertisingGate.shouldAdvertise(power: .unauthorized, serviceAdded: true))
        XCTAssertTrue(AdvertisingGate.shouldAdvertise(power: .poweredOn, serviceAdded: true))
    }
}
