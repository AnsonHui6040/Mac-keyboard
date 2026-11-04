import RemoteKeyboardCore
import SwiftUI

/// The home screen: the setup checklist, the settings pages, help, and the About links.
struct HomeView: View {
    /// Launch argument for UI tests and screenshots: the first launch guide stays away.
    static let skipOnboardingArgument = "-rkSkipOnboarding"

    @AppStorage("rk.onboardingDone") private var onboardingDone = false
    @State private var showsOnboarding = !UserDefaults.standard.bool(forKey: "rk.onboardingDone")
        && !ProcessInfo.processInfo.arguments.contains(HomeView.skipOnboardingArgument)
    @State private var isPaired = PairingStore.loadPairKey() != nil
    @State private var keyboardReady = KeyboardReadyMarker.isReady
    @State private var showsSetupRows = false
    @StateObject private var bluetooth = BluetoothPermission()
    @Environment(\.scenePhase) private var scenePhase

    private var progress: SetupProgress {
        SetupProgress(bluetoothAllowed: bluetooth.isAllowed, isPaired: isPaired, keyboardReady: keyboardReady)
    }

    var body: some View {
        NavigationStack {
            Form {
                setupSection
                Section("設定") {
                    NavigationLink("鍵盤回饋") { KeyFeedbackSettingsView() }
                        .accessibilityIdentifier("rk.home.keyFeedback")
                    NavigationLink("觸控板") { TrackpadSettingsView() }
                        .accessibilityIdentifier("rk.home.trackpad")
                    NavigationLink("中文輸入與手寫") { ChineseInputSettingsView() }
                        .accessibilityIdentifier("rk.home.chineseInput")
                    NavigationLink("聽寫") { DictationSettingsView() }
                        .accessibilityIdentifier("rk.home.dictation")
                }
                Section("幫助") {
                    NavigationLink("使用教學") { TutorialView() }
                        .accessibilityIdentifier("rk.home.tutorial")
                    NavigationLink("測試輸入") { TestInputView() }
                        .accessibilityIdentifier("rk.home.testInputLink")
                    NavigationLink("關於與授權") { AboutView() }
                        .accessibilityIdentifier("rk.home.about")
                }
                Section {
                    if let url = URL(string: AppAbout.githubURL) {
                        Link("GitHub：AnsonHui6040/Mac-keyboard", destination: url)
                            .accessibilityIdentifier("rk.home.github")
                    }
                    NavigationLink("法律聲明") { LegalView() }
                        .accessibilityIdentifier("rk.home.legal")
                } footer: {
                    Text(AppAbout.copyright)
                }
            }
            .navigationTitle("Remote Keyboard")
            .onAppear {
                refresh()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { refresh() }
            }
            .fullScreenCover(isPresented: $showsOnboarding) {
                OnboardingView(bluetooth: bluetooth, onFinish: {
                    onboardingDone = true
                    showsOnboarding = false
                })
            }
            .onChange(of: showsOnboarding) { _, shown in
                if !shown { refresh() }
            }
        }
    }

    private func refresh() {
        bluetooth.refresh()
        isPaired = PairingStore.loadPairKey() != nil
        keyboardReady = KeyboardReadyMarker.isReady
    }

    // MARK: Setup checklist

    /// Three rows until all are done, then one 「設定完成」 row that opens the same rows.
    @ViewBuilder
    private var setupSection: some View {
        if progress.isComplete {
            Section {
                DisclosureGroup(isExpanded: $showsSetupRows) {
                    setupRows
                } label: {
                    Label("設定完成", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                .accessibilityIdentifier("rk.home.setupDone")
            } header: {
                Text("設定進度")
            }
        } else {
            Section {
                setupRows
            } header: {
                Text("設定進度")
            } footer: {
                Text("鍵盤出現過一次後才會打勾。")
            }
        }
    }

    @ViewBuilder
    private var setupRows: some View {
        ForEach(progress.steps, id: \.step) { item in
            switch item.step {
            case .bluetooth:
                bluetoothRow(done: item.isDone)
            case .pairing:
                NavigationLink {
                    MacPairingPage(isPaired: $isPaired)
                } label: {
                    setupLabel("已配對 Mac", done: item.isDone, detail: isPaired ? "已配對" : "尚未配對")
                }
                .accessibilityIdentifier("rk.home.pairing")
            case .keyboard:
                Button { OpenSettings.open() } label: {
                    setupLabel("加入鍵盤並允許完整取用", done: item.isDone, detail: nil)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("rk.home.openSettings")
            }
        }
    }

    @ViewBuilder
    private func bluetoothRow(done: Bool) -> some View {
        Button {
            if bluetooth.isDenied {
                OpenSettings.open()
            } else if !done {
                bluetooth.request()
            }
        } label: {
            setupLabel("藍牙", done: done, detail: bluetooth.statusText)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("rk.home.bluetooth")
        if bluetooth.isDenied {
            Button("到設定開啟藍牙") { OpenSettings.open() }
                .accessibilityIdentifier("rk.home.openBluetoothSettings")
        }
    }

    private func setupLabel(_ title: String, done: Bool, detail: String?) -> some View {
        HStack {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            Text(title)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "已完成" : "未完成")
    }
}

/// 「已配對 Mac」: the pairing status, the pairing screen, and 解除配對.
struct MacPairingPage: View {
    @Binding var isPaired: Bool

    var body: some View {
        Form {
            Section {
                Text(isPaired ? "已配對 Mac" : "尚未配對")
                    .accessibilityIdentifier("rk.home.pairingStatus")
                NavigationLink("配對 Mac") {
                    PairingView(onFinish: { isPaired = PairingStore.loadPairKey() != nil })
                }
                .accessibilityIdentifier("rk.home.pairMac")
                if isPaired {
                    Button("解除配對", role: .destructive) {
                        PairingStore.deletePairKey()
                        isPaired = PairingStore.loadPairKey() != nil
                    }
                    .accessibilityIdentifier("rk.home.unpair")
                }
            } footer: {
                Text("在 Mac 的選單列 App 按「配對新 iPhone」，再回到這裡按「配對 Mac」。")
            }
        }
        .navigationTitle("已配對 Mac")
    }
}
