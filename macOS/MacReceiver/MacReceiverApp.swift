import SwiftUI

@main
struct MacReceiverApp: App {
    @StateObject private var central: ReceiverBLECentral
    @StateObject private var loginItem: LoginItem
    @StateObject private var focus: FocusMonitor
    @StateObject private var testInsert: TestInsertController

    init() {
        let loginItem = LoginItem()
        loginItem.applyDefaultIfNeeded()
        let focus = FocusMonitor()
        focus.start()
        _central = StateObject(wrappedValue: ReceiverBLECentral())
        _loginItem = StateObject(wrappedValue: loginItem)
        _focus = StateObject(wrappedValue: focus)
        _testInsert = StateObject(wrappedValue: TestInsertController(focus: focus))
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
            Text(FocusMenuText.line(focus.snapshot))
            if let snapshot = focus.snapshot, !snapshot.axTrusted {
                Button("授權輔助使用") { focus.requestTrustPrompt() }
            }
            Divider()
            Menu("測試插入") {
                ForEach(TestInsertItem.all) { item in
                    Button(item.label) { testInsert.start(item) }
                }
            }
            if let remaining = testInsert.remaining {
                Text("倒數 \(remaining) 秒")
                Button("取消測試插入") { testInsert.cancel() }
            }
            Text(testInsert.status)
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
