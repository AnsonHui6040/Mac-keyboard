import RemoteKeyboardCore
import SwiftUI

/// 「聽寫」: 「聽寫同步到 Mac」, the one switch the keyboard reads from the App Group for the dictation sync (D18).
struct DictationSettingsView: View {
    @State private var syncsDictation = DictationSync.isEnabled(
        stored: UserDefaults(suiteName: AppGroup.identifier)?.object(forKey: AppGroup.Key.dictationSync))

    var body: some View {
        Form {
            Section {
                Toggle("聽寫同步到 Mac", isOn: $syncsDictation)
                    .accessibilityIdentifier("rk.settings.dictationSync")
            } footer: {
                Text("遠端模式下，用 iPhone 聽寫寫進欄位的文字（包括修改與刪除）會同步到 Mac。關閉後，聽寫只會寫進 iPhone 的欄位。本機模式不會同步。")
            }
        }
        .navigationTitle("聽寫")
        .onChange(of: syncsDictation) { _, enabled in
            UserDefaults(suiteName: AppGroup.identifier)?.set(enabled, forKey: AppGroup.Key.dictationSync)
        }
    }
}
