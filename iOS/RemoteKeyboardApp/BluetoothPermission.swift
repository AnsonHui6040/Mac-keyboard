import CoreBluetooth
import Foundation

/// Creates one `CBCentralManager` so the system shows the Bluetooth permission prompt.
@MainActor
final class BluetoothPermission: NSObject, ObservableObject {
    @Published private(set) var statusText = BluetoothPermission.describe(CBManager.authorization)
    /// `true` when the user has turned Bluetooth off for this app, or it is restricted.
    @Published private(set) var isDenied = BluetoothPermission.isDenied(CBManager.authorization)
    @Published private(set) var isAllowed = CBManager.authorization == .allowedAlways
    private var manager: CBCentralManager?

    /// Re-reads the authorization, for example after the user comes back from Settings.
    func refresh() {
        statusText = Self.describe(CBManager.authorization)
        isDenied = Self.isDenied(CBManager.authorization)
        isAllowed = CBManager.authorization == .allowedAlways
    }

    private static func isDenied(_ authorization: CBManagerAuthorization) -> Bool {
        authorization == .denied || authorization == .restricted
    }

    func request() {
        guard manager == nil else { return }
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    private static func describe(_ authorization: CBManagerAuthorization) -> String {
        switch authorization {
        case .allowedAlways: "已允許"
        case .denied: "已拒絕，請到設定開啟"
        case .restricted: "受限制"
        case .notDetermined: "尚未詢問"
        @unknown default: "未知"
        }
    }
}

extension BluetoothPermission: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        refresh()
    }
}
