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

    @State private var keySound = Self.storedFlag(AppGroup.Key.keySound)
    @State private var keyHaptics = Self.storedFlag(AppGroup.Key.keyHaptics)
    @State private var soundVolume = Self.storedLevels().soundVolume
    @State private var hapticIntensity = Self.storedLevels().hapticIntensity
    /// When a level preview last played; a drag previews at most about eight times a second.
    @State private var lastPreview = Date.distantPast

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
                Toggle("按鍵聲音", isOn: $keySound)
                    .accessibilityIdentifier("rk.settings.keySound")
                levelRow("音量", value: $soundVolume, range: 0...2, id: "rk.settings.soundVolume") {
                    KeyFeedback.previewSound(volume: soundVolume)
                }
                .disabled(!keySound)
                Toggle("按鍵震動", isOn: $keyHaptics)
                    .accessibilityIdentifier("rk.settings.keyHaptics")
                levelRow("震動強度", value: $hapticIntensity, range: 0...1, id: "rk.settings.hapticIntensity") {
                    KeyFeedback.previewHaptic(intensity: hapticIntensity)
                }
                .disabled(!keyHaptics)
            } header: {
                Text("按鍵回饋")
            } footer: {
                Text("音量 100% 約等於系統按鍵聲；聲音跟隨 iPhone 靜音鍵。自訂音量與震動需要在設定中允許完整取用，未允許時改用系統按鍵聲。")
            }
            Section {
                methodRow("手寫", id: .handwriting)
                methodRow("速成", id: .quick)
                Button("開啟完整取用") { OpenSettings.open() }
                    .accessibilityIdentifier("rk.settings.openFullAccess")
            } header: {
                Text("中文輸入")
            } footer: {
                Text("在鍵盤的「中英」鍵切換中文與英文。手寫需要在鍵盤開啟「允許完整取用」；沒有完整取用時，中文頁會改用速成。更改後，重新開啟鍵盤才會生效。")
            }
            Section {
                NavigationLink("授權") { LicensesView() }
                    .accessibilityIdentifier("rk.settings.licenses")
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
        .onAppear {
            downloader.refresh()
            if keySound { KeyClickPlayer.shared.begin() }
        }
        .onDisappear { KeyClickPlayer.shared.stop() }
        .onChange(of: syncsDictation) { _, enabled in
            UserDefaults(suiteName: AppGroup.identifier)?.set(enabled, forKey: AppGroup.Key.dictationSync)
        }
        .onChange(of: keySound) { _, enabled in
            UserDefaults(suiteName: AppGroup.identifier)?.set(enabled, forKey: AppGroup.Key.keySound)
        }
        .onChange(of: keyHaptics) { _, enabled in
            UserDefaults(suiteName: AppGroup.identifier)?.set(enabled, forKey: AppGroup.Key.keyHaptics)
        }
        .onChange(of: soundVolume) { _, volume in
            UserDefaults(suiteName: AppGroup.identifier)?.set(volume, forKey: AppGroup.Key.keySoundVolume)
            previewThrottled { KeyFeedback.previewSound(volume: volume) }
        }
        .onChange(of: hapticIntensity) { _, intensity in
            UserDefaults(suiteName: AppGroup.identifier)?.set(intensity, forKey: AppGroup.Key.keyHapticIntensity)
            previewThrottled { KeyFeedback.previewHaptic(intensity: intensity) }
        }
        .confirmationDialog("刪除手寫模型？", isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("刪除", role: .destructive) { downloader.delete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("刪除後，鍵盤會在下次顯示時移除它的副本，手寫頁需要重新下載模型才能使用。")
        }
    }

    // MARK: Key feedback

    /// A title with the level as a percentage, and a slider in steps of 5%. Letting go previews the level once more
    /// (through the same throttle as the drag, so the last step does not sound twice).
    private func levelRow(
        _ title: String, value: Binding<Double>, range: ClosedRange<Double>, id: String,
        preview: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(Self.percent(value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: 0.05) { editing in
                if !editing { previewThrottled(preview) }
            }
            .accessibilityValue(Self.percent(value.wrappedValue))
            .accessibilityIdentifier(id)
        }
    }

    private func previewThrottled(_ preview: () -> Void) {
        let now = Date()
        guard now.timeIntervalSince(lastPreview) >= 0.12 else { return }
        lastPreview = now
        preview()
    }

    private static func percent(_ level: Double) -> String {
        "\(Int((level * 100).rounded()))%"
    }

    /// The two levels from the App Group; the same rule as the keyboard (default, clamped).
    private static func storedLevels() -> KeyFeedbackSettings {
        let defaults = UserDefaults(suiteName: AppGroup.identifier)
        return KeyFeedbackSettings(
            storedSound: nil, storedHaptics: nil,
            storedVolume: defaults?.object(forKey: AppGroup.Key.keySoundVolume),
            storedIntensity: defaults?.object(forKey: AppGroup.Key.keyHapticIntensity),
            hasFullAccess: true)
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

    /// A `Bool` switch from the App Group; not set means on, the same as the keyboard reads it.
    private static func storedFlag(_ key: String) -> Bool {
        (UserDefaults(suiteName: AppGroup.identifier)?.object(forKey: key) as? Bool) ?? true
    }

    /// The choice the keyboard reads; handwriting until the user picks another.
    private static func savedMethod() -> ChineseInputMethodID {
        ChineseInputMethodID.stored(
            rawValue: UserDefaults(suiteName: AppGroup.identifier)?.string(forKey: AppGroup.Key.chineseMethod))
            ?? .handwriting
    }

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

/// 「授權」: the third-party data and software the app and keyboard use.
private struct LicensesView: View {
    var body: some View {
        List {
            Section("手寫辨識") {
                Text("Google ML Kit Digital Ink Recognition\n條款：https://developers.google.com/ml-kit/terms")
                    .accessibilityIdentifier("rk.licenses.mlkit")
            }
            Section("速成字碼表") {
                Text(Self.quickLicense)
                    .font(.footnote)
                    .accessibilityIdentifier("rk.licenses.quick")
            }
        }
        .navigationTitle("授權")
    }

    private static let quickLicense: String = {
        guard
            let url = Bundle.main.url(forResource: "quick-table-LICENSE", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "找不到授權檔。" }
        return text
    }()
}
