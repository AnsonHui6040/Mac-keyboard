import RemoteKeyboardCore
import SwiftUI

@main
struct RemoteKeyboardApp: App {
    init() {
        // The single pair key of v3 cannot be used any more (the key derivation changed); v4 keeps one key per host.
        PairingStore.removeLegacyKey()
        #if DEBUG
        // TP1: the measurement UI tests pass their settings in the launch environment; the keyboard reads them from the App Group.
        MeasureLaunchConfig.apply()
        // The keyboard's Rime measurement reads this file to prove it can reach the App Group container.
        if let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) {
            try? "ok".write(to: root.appendingPathComponent("rime-probe.txt"), atomically: true, encoding: .utf8)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let name = UserDefaults.standard.string(forKey: "rkPreview") {
                KeyboardPreviewView(stateName: name, width: UserDefaults.standard.double(forKey: "rkPreviewWidth"))
            } else {
                HomeView()
            }
            #else
            HomeView()
            #endif
        }
    }
}
