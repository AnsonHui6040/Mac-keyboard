import RemoteKeyboardCore
import SwiftUI

/// 「鍵盤回饋」: key sound and haptics, each with a level. The keyboard reads the values from the App Group (D21, D23).
struct KeyFeedbackSettingsView: View {
    @State private var keySound = Self.storedFlag(AppGroup.Key.keySound)
    @State private var keyHaptics = Self.storedFlag(AppGroup.Key.keyHaptics)
    @State private var soundVolume = Self.storedLevels().soundVolume
    @State private var hapticIntensity = Self.storedLevels().hapticIntensity
    /// When a level preview last played; a drag previews at most about eight times a second.
    @State private var lastPreview = Date.distantPast

    var body: some View {
        Form {
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
            } footer: {
                Text("音量 100% 約等於系統按鍵聲；聲音跟隨 iPhone 靜音鍵。自訂音量與震動需要在設定中允許完整取用，未允許時改用系統按鍵聲。")
            }
        }
        .navigationTitle("鍵盤回饋")
        .onAppear {
            if keySound { KeyClickPlayer.shared.begin() }
        }
        .onDisappear { KeyClickPlayer.shared.stop() }
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
    }

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

    /// A `Bool` switch from the App Group; not set means on, the same as the keyboard reads it.
    private static func storedFlag(_ key: String) -> Bool {
        (UserDefaults(suiteName: AppGroup.identifier)?.object(forKey: key) as? Bool) ?? true
    }
}
