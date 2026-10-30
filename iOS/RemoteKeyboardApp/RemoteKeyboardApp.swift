import CoreBluetooth
import RemoteKeyboardCore
import SwiftUI

@main
struct RemoteKeyboardApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Creates one `CBCentralManager` so the system shows the Bluetooth permission prompt.
@MainActor
private final class BluetoothPermission: NSObject, ObservableObject {
    @Published private(set) var statusText = BluetoothPermission.describe(CBManager.authorization)
    private var manager: CBCentralManager?

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
        statusText = Self.describe(CBManager.authorization)
    }
}

private struct ContentView: View {
    @State private var probeStatus = "未寫入"
    @State private var keychainStatus = "未寫入"
    @StateObject private var bluetooth = BluetoothPermission()
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("版本：\(BuildStamp.current())")
                }
                Section("測試輸入") {
                    TextField("在這裡輸入", text: $draft)
                }
                Section("App Group") {
                    Button("寫入 probe") {
                        probeStatus = AppGroupProbe.write() ? "已寫入" : "寫入失敗"
                    }
                    Text(probeStatus)
                }
                Section("Keychain") {
                    Button("寫入 Keychain probe") {
                        let result = PairingStore.writeProbe()
                        keychainStatus = "主要：\(result.primary)　備用：\(result.fallback)"
                    }
                    Text(keychainStatus)
                }
                Section("藍牙") {
                    Button("允許藍牙") { bluetooth.request() }
                    Text(bluetooth.statusText)
                }
            }
            .navigationTitle("Remote Keyboard")
        }
    }
}
