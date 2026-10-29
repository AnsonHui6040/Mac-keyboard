import Foundation
import ServiceManagement

/// Seam over `SMAppService.mainApp` so the toggle logic can be tested.
@MainActor
protocol LoginItemService: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: @MainActor LoginItemService {}

/// 「登入時啟動」: registers the Receiver as a login item.
@MainActor
final class LoginItem: ObservableObject {
    static let defaultAppliedKey = "rk.loginItemDefaultApplied"

    @Published private(set) var status: SMAppService.Status

    private let service: LoginItemService
    private let defaults: UserDefaults

    init(service: LoginItemService = SMAppService.mainApp, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        status = service.status
    }

    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    /// Turns the login item on once. A later "off" by the user is never overridden.
    func applyDefaultIfNeeded() {
        guard !defaults.bool(forKey: Self.defaultAppliedKey) else { return refresh() }
        defaults.set(true, forKey: Self.defaultAppliedKey)
        setOn(true)
    }

    func setOn(_ on: Bool) {
        do {
            if on {
                if service.status != .enabled { try service.register() }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            // Status below reflects the failure; no error text is shown or logged.
        }
        refresh()
    }

    func refresh() {
        status = service.status
    }
}
