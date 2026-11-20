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
            Section("輸入引擎（librime）") {
                ForEach(Self.engineComponents, id: \.name) { component in
                    HStack {
                        Text("\(component.name) \(component.version)")
                        Spacer()
                        Text(component.license).foregroundStyle(.secondary)
                    }
                    .font(.footnote)
                }
                .accessibilityIdentifier("rk.licenses.rime.summary")
            }
            Section("輸入引擎授權全文") {
                Text(Self.bundledText("RIME-LICENSES"))
                    .font(.caption2)
                    .accessibilityIdentifier("rk.licenses.rime")
            }
            Section("輸入法資料來源") {
                Text(Self.bundledText("LICENSE-data"))
                    .font(.caption2)
                    .accessibilityIdentifier("rk.licenses.rime.data")
            }
        }
        .navigationTitle("授權")
    }

    private static let engineComponents: [(name: String, version: String, license: String)] = [
        ("librime", "1.17.0", "BSD-3-Clause"),
        ("Boost", "1.92.0", "BSL-1.0"),
        ("LevelDB", "1.23", "BSD-3-Clause"),
        ("marisa-trie", "0.3.1", "BSD-2-Clause"),
        ("yaml-cpp", "0.9.0", "MIT"),
        ("OpenCC", "1.4.2", "Apache-2.0"),
    ]

    private static func bundledText(_ name: String) -> String {
        guard
            let url = Bundle.main.url(forResource: name, withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "找不到授權檔。" }
        return text
    }

    private static let quickLicense: String = {
        guard
            let url = Bundle.main.url(forResource: "quick-table-LICENSE", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return "找不到授權檔。" }
        return text
    }()
}
