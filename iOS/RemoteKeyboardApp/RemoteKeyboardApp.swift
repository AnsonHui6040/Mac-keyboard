import SwiftUI

@main
struct RemoteKeyboardApp: App {
    init() {
        // The single pair key of v3 cannot be used any more (the key derivation changed); v4 keeps one key per host.
        PairingStore.removeLegacyKey()
        #if DEBUG
        // TP1: the measurement UI tests pass their settings in the launch environment; the keyboard reads them from the App Group.
        MeasureLaunchConfig.apply()
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
