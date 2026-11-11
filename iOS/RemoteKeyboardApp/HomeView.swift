import RemoteKeyboardCore
import SwiftUI

/// The home screen: the setup checklist, the settings pages, help, and the About links.
struct HomeView: View {
    /// Launch argument for UI tests and screenshots: the first launch guide stays away.
    static let skipOnboardingArgument = "-rkSkipOnboarding"

    @AppStorage("rk.onboardingDone") private var onboardingDone = false
    @State private var showsOnboarding = HomeView.initialShowsOnboarding
    @State private var isPaired = PairingStore.loadPairKey() != nil
    @State private var keyboardReady = KeyboardReadyMarker.isReady
    @State private var lastLink = LastLinkStore.current
    @State private var showsSetupRows = false
    @StateObject private var bluetooth = BluetoothPermission()
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG
    @State private var showsAutoProbe = AdvertProbe.launchedForAutoRun
    #endif

    private static var initialShowsOnboarding: Bool {
        #if DEBUG
        if AdvertProbe.launchedForAutoRun { return false }
        #endif
        return !UserDefaults.standard.bool(forKey: "rk.onboardingDone")
            && !ProcessInfo.processInfo.arguments.contains(HomeView.skipOnboardingArgument)
    }

    private var progress: SetupProgress {
        SetupProgress(bluetoothAllowed: bluetooth.isAllowed, isPaired: isPaired, keyboardReady: keyboardReady, lastLink: lastLink)
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
                #if DEBUG
                Section {
                    NavigationLink("廣播測試（Debug）") { AdvertProbeView() }
                }
                #endif
            }
            .navigationTitle("Remote Keyboard")
            #if DEBUG
            .navigationDestination(isPresented: $showsAutoProbe) { AdvertProbeView() }
            #endif
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
            .onChange(of: isPaired) { _, _ in
                // A new pairing or 解除配對 clears the stored result; read it again.
                refresh()
            }
        }
    }

    private func refresh() {
        bluetooth.refresh()
        isPaired = PairingStore.loadPairKey() != nil
        keyboardReady = KeyboardReadyMarker.isReady
        lastLink = LastLinkStore.current
        // A problem opens the section each time it is read; the user can still close it by hand.
        if progress.connectionProblem != nil { showsSetupRows = true }
    }

    // MARK: Setup checklist

    /// Three rows until all are done, then one 「設定完成」 row that opens the same rows. A connection problem the keyboard
    /// recorded turns that row into a warning and opens it, with the problem as the first row.
    @ViewBuilder
    private var setupSection: some View {
        if let problem = progress.connectionProblem {
            Section {
                DisclosureGroup(isExpanded: $showsSetupRows) {
                    connectionProblemRow(problem)
                    setupRows
                } label: {
                    Label("連線有問題", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .accessibilityIdentifier("rk.home.setupProblem")
            } header: {
                Text("設定進度")
            } footer: {
                Text("鍵盤下次連上後，這一行會自動消失。")
            }
        } else if progress.isComplete {
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
    private func connectionProblemRow(_ problem: SetupProgress.ConnectionProblem) -> some View {
        switch problem {
        case .authFailed:
            NavigationLink {
                MacPairingPage(isPaired: $isPaired)
            } label: {
                problemLabel("配對驗證失敗，請重新配對")
            }
            .accessibilityIdentifier("rk.home.connectionProblem")
        case .unreachable:
            NavigationLink {
                ConnectionHelpView(isPaired: $isPaired)
            } label: {
                problemLabel("鍵盤上次連不上 Mac")
            }
            .accessibilityIdentifier("rk.home.connectionProblem")
        }
    }

    private func problemLabel(_ title: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(title)
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
                        LastLinkStore.clear()
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
