import SwiftUI

/// 「新增電腦」. Publishes only while this screen is visible. The six digits must match the computer's before 確認.
struct PairingView: View {
    @StateObject private var peripheral = PairingPeripheral()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    /// Called when the screen goes away, so the caller can read the host list again.
    var onFinish: () -> Void = {}

    var body: some View {
        Form {
            switch peripheral.phase {
            case .idle, .preparing:
                Section { Text("正在準備藍牙…") }
            case .waiting:
                Section {
                    Text("在電腦的接收端選單按「配對新 iPhone」（Windows、Linux 為「配對新手機」），這個畫面會自動連上。")
                    if let seconds = peripheral.remainingSeconds {
                        Text(Self.countdown(seconds)).foregroundStyle(.secondary)
                    }
                }
                Section { Button("取消") { leave() } }
            case .confirming(let sas, let host):
                Section("要配對的電腦") {
                    Text(host.name)
                        .accessibilityIdentifier("rk.pairing.hostName")
                    Text(host.platform.displayName)
                        .foregroundStyle(.secondary)
                }
                Section("配對碼") {
                    Text(sas)
                        .font(.system(size: 40, weight: .semibold, design: .monospaced))
                        .accessibilityIdentifier("rk.pairing.sas")
                    Text("與「\(host.name)」畫面上的數字相同時才按確認。")
                        .foregroundStyle(.secondary)
                    if let seconds = peripheral.remainingSeconds {
                        Text(Self.countdown(seconds)).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Button("確認") { peripheral.confirm() }
                    Button("取消", role: .cancel) { leave() }
                }
            case .confirmed:
                Section {
                    Text("已儲存。電腦也按確認之後，再按完成。")
                    if let seconds = peripheral.remainingSeconds {
                        Text(Self.countdown(seconds)).foregroundStyle(.secondary)
                    }
                    Button("完成") { peripheral.finish() }
                }
            case .paired:
                Section {
                    Text("已配對電腦")
                    Button("完成") { leave() }
                }
            case .failed(let failure):
                Section {
                    Text(Self.text(for: failure))
                    if failure == .bluetoothDenied {
                        Button("到設定開啟藍牙") { OpenSettings.open() }
                            .accessibilityIdentifier("rk.pairing.openSettings")
                    }
                    if failure != .hostListFull {
                        Button("重試") {
                            peripheral.stop()
                            peripheral.start()
                        }
                    }
                    Button("返回") { leave() }
                }
            }
        }
        .navigationTitle("新增電腦")
        .onAppear { peripheral.start() }
        // Nothing stays published while the app is in the background; coming back starts a new window.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: peripheral.stop()
            case .active: if peripheral.phase == .idle { peripheral.start() }
            default: break
            }
        }
        .onDisappear {
            peripheral.stop()
            onFinish()
        }
    }

    private func leave() {
        peripheral.cancel()
        dismiss()
    }

    private static func countdown(_ seconds: Int) -> String {
        String(format: "剩餘 %02d:%02d", seconds / 60, seconds % 60)
    }

    private static func text(for failure: PairingPeripheral.Failure) -> String {
        switch failure {
        case .bluetoothOff: "藍牙未開啟，請開啟後再試。"
        case .bluetoothDenied: "尚未允許藍牙，請到設定開啟。"
        case .timedOut: "配對逾時，未儲存。"
        case .connectionLost: "電腦已取消或連線中斷，未儲存。"
        case .mismatch: "配對失敗，未儲存。"
        case .storeFailed: "無法儲存配對，請再試一次。"
        case .publishFailed: "無法開始配對，請再試一次。"
        case .hostListFull: "已達 8 台上限，請先刪除一台"
        }
    }
}
