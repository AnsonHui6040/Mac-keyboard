import SwiftUI

@main
struct MacReceiverApp: App {
    @StateObject private var central: ReceiverBLECentral
    @StateObject private var loginItem: LoginItem

    init() {
        let loginItem = LoginItem()
        loginItem.applyDefaultIfNeeded()
        _central = StateObject(wrappedValue: ReceiverBLECentral())
        _loginItem = StateObject(wrappedValue: loginItem)
    }

    var body: some Scene {
        MenuBarExtra("Remote Keyboard", systemImage: "keyboard") {
            Text(central.linkLabel)
            Text(ReceiverMenu.remainingText(central.remainingSeconds))
            Divider()
            Button("開始接收") { central.startReceiving() }
            Button("停止接收") { central.stopReceiving() }
                .disabled(!central.isArmed)
            Divider()
            Toggle("登入時啟動", isOn: Binding(
                get: { loginItem.isOn },
                set: { loginItem.setOn($0) }
            ))
            if loginItem.needsApproval {
                Text("需在系統設定 › 登入項目 允許")
            }
            Divider()
            Button("結束") { NSApplication.shared.terminate(nil) }
        }
    }
}

enum ReceiverMenu {
    /// 「剩餘接收時間 mm:ss」 while armed, 「待命」 otherwise.
    static func remainingText(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "待命" }
        let total = Int(seconds.rounded(.up))
        return String(format: "剩餘接收時間 %02d:%02d", total / 60, total % 60)
    }
}
