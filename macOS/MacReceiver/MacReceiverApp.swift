import SwiftUI

@main
struct MacReceiverApp: App {
    var body: some Scene {
        MenuBarExtra("Remote Keyboard", systemImage: "keyboard") {
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
