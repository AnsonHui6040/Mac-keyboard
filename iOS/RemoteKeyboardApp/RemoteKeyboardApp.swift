import CoreBluetooth
import CryptoKit
import RemoteKeyboardCore
import SwiftUI

@main
struct RemoteKeyboardApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let name = UserDefaults.standard.string(forKey: "rkPreview") {
                KeyboardPreviewView(stateName: name, width: UserDefaults.standard.double(forKey: "rkPreviewWidth"))
            } else {
                ContentView()
            }
            #else
            ContentView()
            #endif
        }
    }
}

/// Creates one `CBCentralManager` so the system shows the Bluetooth permission prompt.
@MainActor
private final class BluetoothPermission: NSObject, ObservableObject {
    @Published private(set) var statusText = BluetoothPermission.describe(CBManager.authorization)
    /// `true` when the user has turned Bluetooth off for this app, or it is restricted.
    @Published private(set) var isDenied = BluetoothPermission.isDenied(CBManager.authorization)
    private var manager: CBCentralManager?

    /// Re-reads the authorization, for example after the user comes back from Settings.
    func refresh() {
        statusText = Self.describe(CBManager.authorization)
        isDenied = Self.isDenied(CBManager.authorization)
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

private struct ContentView: View {
    @State private var probeStatus = "未寫入"
    @State private var isPaired = PairingStore.loadPairKey() != nil
    @StateObject private var bluetooth = BluetoothPermission()
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("版本：\(BuildStamp.current())")
                }
                Section {
                    Button("打開 iPhone 設定") { OpenSettings.open() }
                        .accessibilityIdentifier("rk.home.openSettings")
                } header: {
                    Text("設定")
                } footer: {
                    Text("在「鍵盤」加入 Remote Keyboard 並開啟「允許完整取用」；藍牙也在同一頁。")
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
                Section("鍵盤") {
                    NavigationLink("中文輸入設定") { SettingsView() }
                }
                Section("Mac 配對") {
                    Text(isPaired ? "已配對 Mac" : "尚未配對")
                    NavigationLink("配對 Mac") {
                        PairingView(onFinish: { isPaired = PairingStore.loadPairKey() != nil })
                    }
                    if isPaired {
                        Button("解除配對", role: .destructive) {
                            PairingStore.deletePairKey()
                            isPaired = PairingStore.loadPairKey() != nil
                        }
                    }
                }
                Section("藍牙") {
                    Button("允許藍牙") { bluetooth.request() }
                    Text(bluetooth.statusText)
                    if bluetooth.isDenied {
                        Button("到設定開啟藍牙") { OpenSettings.open() }
                            .accessibilityIdentifier("rk.home.openBluetoothSettings")
                    }
                }
            }
            .navigationTitle("Remote Keyboard")
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { bluetooth.refresh() }
            }
        }
    }
}
