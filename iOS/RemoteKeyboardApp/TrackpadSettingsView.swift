import RemoteKeyboardCore
import SwiftUI

/// 「觸控板」: pointer sensitivity, the send rate, and whether cursor data may go over Wi-Fi.
struct TrackpadSettingsView: View {
    @State private var trackpadSensitivity = TrackpadSensitivity.resolved(
        appGroup: UserDefaults(suiteName: AppGroup.identifier)?.object(forKey: AppGroup.Key.trackpadSensitivity),
        legacy: nil
    ).value

    /// Same read as the keyboard: App Group first, then the extension's own defaults.
    @State private var trackpadSendRate = TrackpadSendRate.clamped(
        UserDefaults(suiteName: AppGroup.identifier)?.object(forKey: AppGroup.Key.trackpadSendRate)
            ?? UserDefaults.standard.object(forKey: AppGroup.Key.trackpadSendRate))

    /// 「經 Wi-Fi 傳送游標」, read by the keyboard when it opens the touchpad channel (`WifiPointerSetting`).
    @State private var wifiPointerOn = WifiPointerSetting.isEnabled(
        stored: UserDefaults(suiteName: AppGroup.identifier)?.object(forKey: AppGroup.Key.wifiPointer))

    var body: some View {
        Form {
            Section {
                Stepper(
                    value: $trackpadSensitivity, in: TrackpadSensitivity.minimum...TrackpadSensitivity.maximum,
                    step: TrackpadSensitivity.step
                ) {
                    HStack {
                        Text("靈敏度")
                        Spacer()
                        Text(TrackpadSensitivity.displayText(trackpadSensitivity))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("rk.settings.trackpadSensitivityValue")
                    }
                }
                .accessibilityIdentifier("rk.settings.trackpadSensitivity")
                Stepper {
                    HStack {
                        Text("傳輸次數")
                        Spacer()
                        Text(TrackpadSendRate.displayText(trackpadSendRate))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("rk.settings.trackpadSendRateValue")
                    }
                } onIncrement: {
                    trackpadSendRate = TrackpadSendRate.stepped(trackpadSendRate, by: 1)
                } onDecrement: {
                    trackpadSendRate = TrackpadSendRate.stepped(trackpadSendRate, by: -1)
                }
                .accessibilityIdentifier("rk.settings.trackpadSendRate")
            } footer: {
                Text("調整單指移動與拖曳時游標移動的距離。傳輸次數是游標每秒最多傳送的次數，自動則依連線狀況決定。更改後，下次開啟鍵盤時生效。")
            }
            Section {
                Toggle("經 Wi-Fi 傳送游標", isOn: $wifiPointerOn)
                    .accessibilityIdentifier("rk.settings.wifiPointer")
            } footer: {
                Text("開啟後，如果電腦和這支 iPhone 在同一個 Wi-Fi，游標資料會直接經 Wi-Fi 傳送，否則仍經藍牙傳送。需要允許「區域網路」權限；曾經拒絕的話，請到 iPhone「設定」裡的「Remote Keyboard」打開。更改後，下次開啟觸控板時生效。")
            }
        }
        .navigationTitle("觸控板")
        .onAppear {
            if wifiPointerOn { LocalNetworkPermission.trigger() }
        }
        .onChange(of: wifiPointerOn) { _, isOn in
            UserDefaults(suiteName: AppGroup.identifier)?.set(isOn, forKey: AppGroup.Key.wifiPointer)
            if isOn { LocalNetworkPermission.trigger() }
        }
        .onChange(of: trackpadSensitivity) { _, value in
            UserDefaults(suiteName: AppGroup.identifier)?.set(
                TrackpadSensitivity.clamped(value), forKey: AppGroup.Key.trackpadSensitivity)
        }
        .onChange(of: trackpadSendRate) { _, rate in
            let value = TrackpadSendRate.clamped(rate)
            UserDefaults(suiteName: AppGroup.identifier)?.set(value, forKey: AppGroup.Key.trackpadSendRate)
            UserDefaults.standard.set(value, forKey: AppGroup.Key.trackpadSendRate)
        }
    }
}
