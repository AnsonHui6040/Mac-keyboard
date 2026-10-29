import SwiftUI

@main
struct RemoteKeyboardApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

private struct ContentView: View {
    @State private var probeStatus = "未寫入"
    @State private var draft = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("測試輸入") {
                    TextField("在這裡輸入", text: $draft)
                }
                Section("App Group") {
                    Button("寫入 probe") {
                        probeStatus = AppGroupProbe.write() ? "已寫入" : "寫入失敗"
                    }
                    Text(probeStatus)
                }
            }
            .navigationTitle("Remote Keyboard")
        }
    }
}
