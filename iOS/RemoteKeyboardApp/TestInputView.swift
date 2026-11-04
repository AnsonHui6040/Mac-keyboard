import SwiftUI

/// 「測試輸入」: a plain field to bring up the keyboard in this App without opening another one.
struct TestInputView: View {
    @State private var draft = ""

    var body: some View {
        Form {
            Section {
                TextField("在這裡輸入", text: $draft)
                    .accessibilityIdentifier("rk.home.testInput")
            } footer: {
                Text("點一下欄位叫出鍵盤，按住地球鍵選 Remote Keyboard。")
            }
        }
        .navigationTitle("測試輸入")
    }
}
