import RemoteKeyboardCore
import SwiftUI

/// 「觸控板」: pointer sensitivity and the send rate the keyboard's trackpad uses.
struct TrackpadSettingsView: View {
    @State private var trackpadSensitivity = TrackpadSensitivity.resolved(
        appGroup: UserDefaults(suiteName: AppGroup.identifier)?.object(forKey: AppGroup.Key.trackpadSensitivity),
        legacy: nil
    ).value

    /// Same read as the keyboard: App Group first, then the extension's own defaults.
    @State private var trackpadSendRate = TrackpadSendRate.clamped(
        UserDefaults(suiteName: AppGroup.identifier)?.object(forKey: AppGroup.Key.trackpadSendRate)
            ?? UserDefaults.standard.object(forKey: AppGroup.Key.trackpadSendRate))

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
        }
        .navigationTitle("觸控板")
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
