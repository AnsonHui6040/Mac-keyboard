import SwiftUI

/// 「鍵盤上次連不上電腦」: what to check, in order, and the pairing page for when that still fails.
struct ConnectionHelpView: View {
    @Binding var isPaired: Bool

    private static let steps = [
        "在電腦打開 Remote Keyboard Receiver",
        "Mac：按面板的「開始接收」。Windows、Linux：接收端執行中即可",
        "確認電腦與 iPhone 的藍牙都開著",
        "確認狀態格顯示的是要用的電腦，把鍵盤切到「遠端」再試一次",
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
                    Text("\(index + 1). \(step)")
                }
            }
            Section {
                NavigationLink("到配對頁") { HostListPage(isPaired: $isPaired) }
                    .accessibilityIdentifier("rk.home.connectionHelp.pairing")
            } footer: {
                Text("照上面做了還是連不上時，重新配對一次。")
            }
        }
        .navigationTitle("連不上電腦")
        .accessibilityIdentifier("rk.home.connectionHelp")
    }
}
