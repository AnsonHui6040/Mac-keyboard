import SwiftUI

/// The first launch guide: four pages, skippable. Shown as a full screen cover by `ContentView`.
struct OnboardingView: View {
    @ObservedObject var bluetooth: BluetoothPermission
    var onFinish: () -> Void

    @State private var page = 0

    private static let pageCount = 4

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("略過") { onFinish() }
                    .accessibilityIdentifier("rk.onboarding.skip")
            }
            .padding([.horizontal, .top])
            TabView(selection: $page) {
                pageView(
                    symbol: "keyboard", title: "這個 App 做什麼",
                    text: "把 iPhone 變成 Mac 的藍牙鍵盤與觸控板。在 iPhone 打字，文字會經藍牙加密送到 Mac 目前的欄位。"
                ).tag(0)
                pageView(
                    symbol: "desktopcomputer", title: "在 Mac 安裝 Receiver",
                    text: "Mac 需要安裝 Remote Keyboard Receiver，它會在選單列顯示鍵盤圖示。安裝與開啟方式見手冊的「安裝 Mac Receiver」。"
                ).tag(1)
                pageView(
                    symbol: "lock.open", title: "開啟權限與加入鍵盤",
                    text: "允許藍牙。再到 iPhone 設定的「鍵盤」加入 Remote Keyboard，並開啟「允許完整取用」。"
                ) {
                    Button(bluetooth.isDenied ? "到設定開啟藍牙" : "允許藍牙") {
                        if bluetooth.isDenied { OpenSettings.open() } else { bluetooth.request() }
                    }
                        .buttonStyle(.bordered)
                        .disabled(bluetooth.isAllowed)
                        .accessibilityIdentifier("rk.onboarding.bluetooth")
                    Button("打開 iPhone 設定") { OpenSettings.open() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("rk.onboarding.openSettings")
                }.tag(2)
                pageView(
                    symbol: "link", title: "配對電腦",
                    text: "1 在電腦的接收端選單按「配對新 iPhone」（Windows、Linux 為「配對新手機」）。\n2 在這個 App 首頁的「已配對電腦」按「新增電腦」。\n3 兩邊的配對碼相同時，各按確認。"
                ).tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            Button {
                if page == Self.pageCount - 1 { onFinish() } else { page += 1 }
            } label: {
                Text(page == Self.pageCount - 1 ? "完成" : "下一步")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .accessibilityIdentifier(page == Self.pageCount - 1 ? "rk.onboarding.done" : "rk.onboarding.next")
        }
        .onChange(of: page) { _, _ in bluetooth.refresh() }
    }

    private func pageView(
        symbol: String, title: String, text: String, @ViewBuilder extra: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 64))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(text)
                .multilineTextAlignment(.leading)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            extra()
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}
