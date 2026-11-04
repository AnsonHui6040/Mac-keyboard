import RemoteKeyboardCore
import SwiftUI

enum MacTutorialWindow {
    static let id = "tutorial"
}

/// 「使用教學」: a window of its own, opened from the panel. Three steps, what the app does, links to the manual, and the
/// legal notes at the bottom.
struct MacTutorialView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                section("三步開始") {
                    Text("1 在 Mac 允許輔助使用與藍牙，按選單列面板的「開始接收」。")
                    Text("2 在 iPhone 開啟 Remote Keyboard App，到「已配對 Mac」按「配對 Mac」。Mac 按「配對新 iPhone」，兩邊核對配對碼後按確認。")
                    Text("3 在 iPhone 任一個輸入框切換到 Remote Keyboard，選「遠端」，Mac 目前的文字欄位就會收到文字。")
                }
                section("功能簡介") {
                    Text("文字：iPhone 打的字經藍牙加密送到 Mac 目前的欄位。即時模式每按一個鍵就送出，草稿模式按「傳送」才一次送出。")
                    Text("觸控板：在面板勾選「允許觸控板控制」後，iPhone 鍵盤區可以當作觸控板移動游標、點按、拖曳與捲動。")
                    Text("密碼：Mac 在密碼欄、開啟安全輸入或螢幕鎖定時，不會輸入文字。")
                }
                section("更多說明") {
                    if let manual = URL(string: AppAbout.manualURL) {
                        Link("看完整手冊", destination: manual)
                    }
                    if let github = URL(string: AppAbout.githubURL) {
                        Link("GitHub：AnsonHui6040/Mac-keyboard", destination: github)
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppAbout.copyright)
                    Text(AppAbout.disclaimer)
                    Text(AppAbout.thirdParty)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 420, height: 560)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content()
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
