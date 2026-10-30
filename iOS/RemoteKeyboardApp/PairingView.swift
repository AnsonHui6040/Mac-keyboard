import SwiftUI

/// 「配對 Mac」. Publishes only while this screen is visible. The six digits must match the Mac's before 確認.
struct PairingView: View {
    @StateObject private var peripheral = PairingPeripheral()
    @Environment(\.dismiss) private var dismiss
    /// Called when the screen goes away, so the caller can re-read whether a pair key is stored.
    var onFinish: () -> Void = {}

    var body: some View {
        Form {
            switch peripheral.phase {
            case .idle, .preparing:
                Section { Text("正在準備藍牙…") }
            case .waiting:
                Section {
                    Text("在 Mac 的選單列 App 按「配對新 iPhone」，這個畫面會自動連上。")
                    if let seconds = peripheral.remainingSeconds {
                        Text(Self.countdown(seconds)).foregroundStyle(.secondary)
                    }
                }
                Section { Button("取消") { leave() } }
            case .confirming(let sas):
                Section("配對碼") {
                    Text(sas)
                        .font(.system(size: 40, weight: .semibold, design: .monospaced))
                        .accessibilityIdentifier("rk.pairing.sas")
                    Text("與 Mac 畫面上的數字相同時才按確認。")
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
                    Text("已儲存。Mac 也按確認之後，再按完成。")
                    if let seconds = peripheral.remainingSeconds {
                        Text(Self.countdown(seconds)).foregroundStyle(.secondary)
                    }
                    Button("完成") { peripheral.finish() }
                }
            case .paired:
                Section {
                    Text("已配對 Mac")
                    Button("完成") { leave() }
                }
            case .failed(let failure):
                Section {
                    Text(Self.text(for: failure))
                    Button("重試") {
                        peripheral.stop()
                        peripheral.start()
                    }
                    Button("返回") { leave() }
                }
            }
        }
        .navigationTitle("配對 Mac")
        .onAppear { peripheral.start() }
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
        case .connectionLost: "Mac 已取消或連線中斷，未儲存。"
        case .mismatch: "配對失敗，未儲存。"
        case .storeFailed: "無法儲存配對，請再試一次。"
        case .publishFailed: "無法開始配對，請再試一次。"
        }
    }
}
