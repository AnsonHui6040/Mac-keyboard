import RemoteKeyboardCore
import SwiftUI

/// 「關於與授權」: the build, the third-party licences, and in Debug builds the App Group probe.
struct AboutView: View {
    #if DEBUG
    @State private var probeStatus = "未寫入"
    #endif

    var body: some View {
        Form {
            Section {
                Text("版本：\(BuildStamp.current())")
                NavigationLink("授權") { LicensesView() }
                    .accessibilityIdentifier("rk.settings.licenses")
            }
            #if DEBUG
            Section("App Group") {
                Button("寫入 probe") {
                    probeStatus = AppGroupProbe.write() ? "已寫入" : "寫入失敗"
                }
                Text(probeStatus)
            }
            #endif
        }
        .navigationTitle("關於與授權")
    }
}

/// 「授權」: the third-party data and software the app and keyboard use.
struct LicensesView: View {
    var body: some View {
        List {
            Section("手寫辨識") {
                Text("Google ML Kit Digital Ink Recognition\n條款：https://developers.google.com/ml-kit/terms")
                    .accessibilityIdentifier("rk.licenses.mlkit")
            }
            Section("速成字碼表") {
                Text(Self.quickLicense)
                    .font(.footnote)
                    .accessibilityIdentifier("rk.licenses.quick")
            }
        }
        .navigationTitle("授權")
    }

    private static let quickLicense: String = {
        guard
            let url = Bundle.main.url(forResource: "quick-table-LICENSE", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "找不到授權檔。" }
        return text
    }()
}
