import SwiftUI

@main
struct RemoteKeyboardApp: App {
    #if DEBUG
    init() {
        // TP1: the measurement UI tests pass their settings in the launch environment; the keyboard reads them from the App Group.
        MeasureLaunchConfig.apply()
    }
    #endif

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
