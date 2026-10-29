import AppKit
import RemoteKeyboardCore
import SwiftUI

/// The menu bar panel. A window style panel is used instead of a menu because a menu cannot be clicked reliably while
/// its rows change every second (countdown, focus line). The width is fixed so changing text never resizes it.
struct ReceiverPanel: View {
    static let width: CGFloat = 280

    @ObservedObject var central: ReceiverBLECentral
    @ObservedObject var focus: FocusMonitor
    @ObservedObject var testInsert: TestInsertController
    @ObservedObject var loginItem: LoginItem

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("版本：\(BuildStamp.current())")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(central.linkLabel)
                Text(ReceiverMenu.remainingText(central.remainingSeconds))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("開始接收") { central.startReceiving() }
                Button("停止接收") { central.stopReceiving() }
                    .disabled(!central.isArmed)
            }
            Divider()
            Text(FocusMenuText.line(focus.snapshot))
                .fixedSize(horizontal: false, vertical: true)
            if let snapshot = focus.snapshot, !snapshot.axTrusted {
                Button("授權輔助使用") { focus.requestTrustPrompt() }
            }
            Divider()
            Text("測試插入").font(.headline)
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(TestInsertItem.all.filter(\.chunked)) { item in
                    Button(item.label) { testInsert.start(item) }
                        .frame(maxWidth: .infinity)
                }
            }
            ForEach(TestInsertItem.all.filter { !$0.chunked }) { item in
                Button(item.label) { testInsert.start(item) }
                    .frame(maxWidth: .infinity)
            }
            if let remaining = testInsert.remaining {
                HStack {
                    Text("倒數 \(remaining) 秒")
                    Spacer()
                    Button("取消測試插入") { testInsert.cancel() }
                }
            }
            Text(testInsert.status)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            Toggle("登入時啟動", isOn: Binding(
                get: { loginItem.isOn },
                set: { loginItem.setOn($0) }
            ))
            if loginItem.needsApproval {
                Text("需在系統設定 › 登入項目 允許")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Button("結束") { NSApplication.shared.terminate(nil) }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
    }
}
