import RemoteKeyboardCore
import SwiftUI

/// The pairing block of the menu bar panel: the phone that is connected, the list of paired phones (name, platform, delete) and
/// the pairing prompt. It is inline rather than a modal sheet: the panel is a small window that closes with the menu, and the
/// prompt must stay where the user is already looking.
struct PairingSheet: View {
    @ObservedObject var security: ReceiverSecurity
    /// The central's once-a-second clock, so the countdown redraws.
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch security.phase {
            case .idle:
                if let name = security.connectedPhoneName {
                    Text("目前連線：\(name)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(security.isPaired ? "已配對的手機" : "配對：尚未配對")
                ForEach(security.phones, id: \.id) { phone in
                    HStack(spacing: 6) {
                        Text(phone.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(Self.platformName(phone.platform))
                            .foregroundStyle(.secondary)
                            .layoutPriority(1)
                        Spacer(minLength: 0)
                        Button("刪除") { security.removePhone(id: phone.id) }
                            .accessibilityLabel("刪除 \(phone.name)")
                    }
                }
                if let result = security.lastResult {
                    Text(Self.resultText(result))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("配對新 iPhone") { security.openPairingWindow() }
            case .waiting:
                Text("請在 iPhone 的 Remote Keyboard 開啟「配對 Mac」")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(Self.countdownText(security.windowRemaining(at: now)))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("取消") { security.cancelPairing() }
                }
            case .confirming(let sas):
                if let name = security.pairingPhoneName {
                    Text("手機：\(name)")
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text("請核對 iPhone 上的配對碼")
                Text(sas)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .accessibilityIdentifier("rk.pairing.sas")
                Text("兩邊相同才按確認")
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("確認") { security.confirmPairing() }
                        .keyboardShortcut(.defaultAction)
                    Button("取消") { security.cancelPairing() }
                }
                Text(Self.countdownText(security.windowRemaining(at: now)))
                    .foregroundStyle(.secondary)
            case .confirmed:
                Text("已儲存。iPhone 也按確認之後，再按完成。")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(Self.countdownText(security.windowRemaining(at: now)))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("完成") { security.finishPairing() }
                }
            }
        }
    }

    static func platformName(_ platform: PhonePlatform) -> String {
        switch platform {
        case .ios: "iPhone"
        case .android: "Android"
        }
    }

    static func countdownText(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "" }
        let total = Int(seconds.rounded(.up))
        return String(format: "剩餘 %02d:%02d", total / 60, total % 60)
    }

    static func resultText(_ result: ReceiverSecurity.PairingResult) -> String {
        switch result {
        case .paired: "配對完成"
        case .cancelled: "配對已取消"
        case .timedOut: "配對逾時，未儲存"
        case .failed: "配對失敗，未儲存"
        case .storeFailed: "無法儲存配對，請再試一次"
        case .full: "已配對 8 支手機，請先刪除一支"
        }
    }
}
