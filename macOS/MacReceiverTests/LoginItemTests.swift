import ServiceManagement
import XCTest
@testable import MacReceiver

@MainActor
private final class FakeLoginService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var statusAfterRegister: SMAppService.Status = .enabled
    var registerCount = 0
    var unregisterCount = 0
    func register() throws { registerCount += 1; status = statusAfterRegister }
    func unregister() throws { unregisterCount += 1; status = .notRegistered }
}

@MainActor
final class LoginItemTests: XCTestCase {
    private var defaults: UserDefaults!
    private var service: FakeLoginService!

    override func setUp() async throws {
        let name = "rk.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)
        defaults.removePersistentDomain(forName: name)
        service = FakeLoginService()
    }

    func testFirstLaunchRegistersOnce() {
        let item = LoginItem(service: service, defaults: defaults)
        item.applyDefaultIfNeeded()
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertEqual(item.status, .enabled)
        XCTAssertTrue(item.isOn)
    }

    func testUserOffSticksAcrossLaunches() {
        let first = LoginItem(service: service, defaults: defaults)
        first.applyDefaultIfNeeded()
        first.setOn(false)
        XCTAssertFalse(first.isOn)

        let second = LoginItem(service: service, defaults: defaults)
        second.applyDefaultIfNeeded()
        XCTAssertEqual(service.registerCount, 1)
        XCTAssertFalse(second.isOn)
    }

    func testRequiresApprovalIsReported() {
        service.statusAfterRegister = .requiresApproval
        let item = LoginItem(service: service, defaults: defaults)
        item.applyDefaultIfNeeded()
        XCTAssertTrue(item.needsApproval)
    }
}
