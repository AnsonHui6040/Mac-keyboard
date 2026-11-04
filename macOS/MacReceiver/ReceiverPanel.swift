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
    @ObservedObject var security: ReceiverSecurity
    @ObservedObject var notice: InputSourceNotice
    @ObservedObject var pointer: PointerReceiver
    #if DEBUG
    @ObservedObject var burstVerifier: BurstVerifier
    @ObservedObject var measurement: MeasurementEcho
    #endif

    /// Set to true to bring back the 「測試插入」 and 「除錯」 sections.
    private static let showsDeveloperTools = false

    @Environment(\.openWindow) private var openWindow

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            warnings
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Self.dotColor(central.linkState))
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(central.linkLabel)
                }
                Text(FocusMenuText.line(focus.snapshot))
                    .fixedSize(horizontal: false, vertical: true)
                Text(ReceiverMenu.remainingText(central.remainingSeconds))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("開始接收") { central.startReceiving() }
                Button("停止接收") { central.stopReceiving() }
                    .disabled(!central.isArmed)
            }
            if Self.showsDeveloperTools {
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
                #if DEBUG
                Divider()
                Text("除錯").font(.headline)
                Button("驗證 burst") { burstVerifier.verify() }
                    .disabled(burstVerifier.isRunning)
                Text(burstVerifier.status)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("量測模式", isOn: Binding(
                    get: { measurement.isMeasureMode },
                    set: { measurement.setMeasureMode($0) }
                ))
                Text(measurement.summary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                #endif
            }
            Divider()
            PairingSheet(security: security, now: central.now)
            if !security.isPaired, case .idle = security.phase {
                VStack(alignment: .leading, spacing: 2) {
                    Text("1 在 iPhone 開啟 Remote Keyboard App")
                    Text("2 按「配對新 iPhone」")
                    Text("3 兩邊核對配對碼後按確認")
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Toggle("允許觸控板控制", isOn: Binding(
                get: { pointer.isEnabled },
                set: { pointer.setEnabled($0) }
            ))
            if pointer.isOpen {
                Text("觸控板使用中")
                    .foregroundStyle(.secondary)
                if Self.showsDeveloperTools, let summary = pointer.linkSummary {
                    Text("觸控板連線")
                    ForEach(summary + (pointer.playoutSummary ?? []), id: \.self) { line in
                        Text(line).foregroundStyle(.secondary)
                    }
                }
            }
            Toggle("登入時啟動", isOn: Binding(
                get: { loginItem.isOn },
                set: { loginItem.setOn($0) }
            ))
            if loginItem.needsApproval {
                Text("需在系統設定 › 登入項目 允許")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打開登入項目設定") { SystemSettings.open(.loginItems) }
            }
            Divider()
            Text("系統設定").font(.headline)
            HStack(spacing: 6) {
                Button("輔助使用") { SystemSettings.open(.accessibility) }
                Button("藍牙") { SystemSettings.open(.bluetoothPrivacy) }
                Button("登入項目") { SystemSettings.open(.loginItems) }
            }
            Divider()
            HStack(spacing: 8) {
                Button("使用教學") {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openWindow(id: MacTutorialWindow.id)
                }
                Text("版本：\(BuildStamp.current())")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button("結束") { NSApplication.shared.terminate(nil) }
            }
        }
        .font(.callout)
        .controlSize(.small)
        .padding(12)
        .frame(width: Self.width, alignment: .leading)
    }

    /// Red warnings first: missing Accessibility, the Bluetooth reason, a failed input source restore.
    @ViewBuilder
    private var warnings: some View {
        if let snapshot = focus.snapshot, !snapshot.axTrusted {
            VStack(alignment: .leading, spacing: 6) {
                Text("尚未授權輔助使用，無法輸入文字")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("授權輔助使用") { focus.requestTrustPrompt() }
                    Button("打開輔助使用設定") { SystemSettings.open(.accessibility) }
                }
            }
        }
        if let reason = central.linkReason {
            VStack(alignment: .leading, spacing: 6) {
                Text(reason)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if central.needsBluetoothPermission {
                    Button("打開藍牙設定") { SystemSettings.open(.bluetoothPrivacy) }
                }
            }
        }
        if let message = notice.message {
            Text(message)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Green when connected, orange while looking or connecting, grey when not receiving, red when the radio is unusable.
    private static func dotColor(_ state: ReceiverLinkState) -> Color {
        switch state {
        case .ready: .green
        case .scanning, .connecting, .discovering: .orange
        case .idle: .gray
        case .unavailable: .red
        }
    }
}
