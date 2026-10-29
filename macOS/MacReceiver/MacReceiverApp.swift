import SwiftUI

@main
struct MacReceiverApp: App {
    @StateObject private var server: GATTPeripheralServer

    init() {
        let server = GATTPeripheralServer()
        server.start()
        _server = StateObject(wrappedValue: server)
    }

    var body: some Scene {
        MenuBarExtra("Remote Keyboard", systemImage: "keyboard") {
            Text("BLE: \(server.state.label)")
            Divider()
            Button("Start") { server.start() }
                .disabled(server.state != .idle && !isFailed)
            Button("Stop") { server.stop() }
                .disabled(server.state == .idle)
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    private var isFailed: Bool {
        if case .failed = server.state { return true }
        return false
    }
}
