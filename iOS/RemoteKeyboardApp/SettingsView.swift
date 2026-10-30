import RemoteKeyboardCore
import SwiftUI

/// 「中文輸入設定」: which Chinese input method the keyboard uses, and the handwriting model it needs. Also holds
/// 「聽寫同步到 Mac」, the one switch the keyboard reads from the App Group for the dictation sync (D18).
struct SettingsView: View {
    @StateObject private var downloader = HandwritingModelDownloader()
    @State private var method = Self.savedMethod()
    @State private var confirmsDelete = false
    @State private var syncsDictation = DictationSync.isEnabled(
        stored: UserDefaults(suiteName: AppGroup.identifier)?.object(forKey: AppGroup.Key.dictationSync))

    var body: some View {
        Form {
            Section {
                Toggle("聽寫同步到 Mac", isOn: $syncsDictation)
                    .accessibilityIdentifier("rk.settings.dictationSync")
            } header: {
                Text("聽寫")
            } footer: {
                Text("遠端模式下，用 iPhone 聽寫寫進欄位的文字（包括修改與刪除）會同步到 Mac。關閉後，聽寫只會寫進 iPhone 的欄位。本機模式不會同步。")
            }
            Section {
                methodRow("手寫", id: .handwriting)
                HStack {
                    Label("速成", systemImage: "circle")
                    Spacer()
                    Text("即將推出").foregroundStyle(.secondary)
                }
                .foregroundStyle(.tertiary)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("rk.settings.quick")
            } header: {
                Text("中文輸入")
            } footer: {
                Text("在鍵盤的「中英」鍵切換中文與英文。手寫需要在鍵盤開啟「允許完整取用」。")
            }
            Section {
                Text(statusText)
                    .accessibilityIdentifier("rk.settings.modelStatus")
                if case .downloading(let fraction) = downloader.state {
                    if let fraction {
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                }
                Button("下載手寫模型") { downloader.start() }
                    .disabled(downloader.isBusy || !canDownload)
                    .accessibilityIdentifier("rk.settings.download")
                Button("刪除手寫模型", role: .destructive) { confirmsDelete = true }
                    .disabled(downloader.isBusy || !hasModel)
                    .accessibilityIdentifier("rk.settings.delete")
            } header: {
                Text("手寫模型")
            } footer: {
                Text("手寫辨識使用 Google ML Kit。模型約 30 MB，下載一次後，鍵盤會自動匯入，之後不需要網路。")
            }
        }
        .navigationTitle("中文輸入設定")
        .onAppear { downloader.refresh() }
        .onChange(of: syncsDictation) { _, enabled in
            UserDefaults(suiteName: AppGroup.identifier)?.set(enabled, forKey: AppGroup.Key.dictationSync)
        }
        .confirmationDialog("刪除手寫模型？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("刪除", role: .destructive) { downloader.delete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("刪除後，鍵盤會在下次顯示時移除它的副本，手寫頁需要重新下載模型才能使用。")
        }
    }

    // MARK: Method

    private func methodRow(_ title: String, id: ChineseInputMethodID) -> some View {
        Button {
            method = id
            UserDefaults(suiteName: AppGroup.identifier)?.set(id.rawValue, forKey: AppGroup.Key.chineseMethod)
        } label: {
            HStack {
                Label(title, systemImage: method == id ? "largecircle.fill.circle" : "circle")
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("rk.settings.\(id.rawValue)")
        .accessibilityAddTraits(method == id ? .isSelected : [])
    }

    /// Quick is not selectable yet, so the choice shown is always handwriting.
    private static func savedMethod() -> ChineseInputMethodID { .handwriting }

    // MARK: Model

    private var hasModel: Bool {
        if case .ready = downloader.state { return true }
        return false
    }

    private var canDownload: Bool {
        if case .ready = downloader.state { return false }
        return true
    }

    private var statusText: String {
        switch downloader.state {
        case .notDownloaded: "尚未下載"
        case .downloading(let fraction):
            fraction.map { "下載中 \(Int($0 * 100))%" } ?? "下載中…"
        case .copying: "正在放入鍵盤共用位置…"
        case .ready(let bytes): "已下載（\(Self.megabytes(bytes))）"
        case .failed(let reason): "失敗：\(reason)"
        }
    }

    private static func megabytes(_ bytes: Int64) -> String {
        String(format: "%.0f MB", Double(bytes) / 1_048_576)
    }
}
