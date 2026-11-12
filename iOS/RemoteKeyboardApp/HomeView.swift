import RemoteKeyboardCore
import SwiftUI

/// The home screen: the setup checklist, the settings pages, help, and the About links.
struct HomeView: View {
    /// Launch argument for UI tests and screenshots: the first launch guide stays away.
    static let skipOnboardingArgument = "-rkSkipOnboarding"

    @AppStorage("rk.onboardingDone") private var onboardingDone = false
    @State private var showsOnboarding = HomeView.initialShowsOnboarding
    @State private var isPaired = PairingStore.hasHost
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
        isPaired = PairingStore.hasHost
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
                HostListPage(isPaired: $isPaired)
            } label: {
                problemLabel("配對驗證失敗，請重新配對")
            }
            .accessibilityIdentifier("rk.home.connectionProblem")
        case .unreachable:
            NavigationLink {
                ConnectionHelpView(isPaired: $isPaired)
            } label: {
                problemLabel("鍵盤上次連不上電腦")
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
                    HostListPage(isPaired: $isPaired)
                } label: {
                    setupLabel("已配對電腦", done: item.isDone, detail: isPaired ? "已配對" : "尚未配對")
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

/// 「已配對電腦」: the paired hosts, one row each (name and platform, a check mark on the current one), and 新增電腦.
/// Tapping a row makes that host the current one; swiping a row left asks to delete it (its pair key goes too).
struct HostListPage: View {
    @Binding var isPaired: Bool
    @State private var selection = PairingStore.loadHosts()
    @State private var pendingDelete: HostIdentity?

    private var isFull: Bool { selection.hosts.count >= PairedList<PairedHost>.capacity }

    var body: some View {
        Form {
            Section {
                if selection.hosts.isEmpty {
                    Text("尚未配對")
                        .accessibilityIdentifier("rk.home.pairingStatus")
                }
                ForEach(selection.hosts, id: \.id) { host in
                    row(host)
                }
            } header: {
                if !selection.hosts.isEmpty { Text("電腦") }
            }
            Section {
                NavigationLink("新增電腦") {
                    PairingView(onFinish: reload)
                }
                .disabled(isFull)
                .accessibilityIdentifier("rk.home.pairMac")
            } footer: {
                if isFull {
                    Text("已達 8 台上限，請先刪除一台")
                } else {
                    Text("在電腦的接收端選單按「配對新 iPhone」（Windows、Linux 為「配對新手機」），再回到這裡按「新增電腦」。")
                }
            }
        }
        .navigationTitle("已配對電腦")
        .onAppear(perform: reload)
        .confirmationDialog(
            pendingDelete.map { "刪除「\($0.name)」？" } ?? "", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("刪除", role: .destructive) {
                if let host = pendingDelete { delete(host) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("刪除後，這支 iPhone 不再連到這台電腦，要用的話需重新配對。")
        }
    }

    private func row(_ host: HostIdentity) -> some View {
        let isCurrent = host.id == selection.selectedId
        return Button {
            choose(host)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(host.name).foregroundStyle(.primary)
                    Text(host.platform.displayName).font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isCurrent ? "目前使用" : "")
        .accessibilityIdentifier("rk.home.host")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("刪除", role: .destructive) { pendingDelete = host }
        }
    }

    private func choose(_ host: HostIdentity) {
        var updated = PairingStore.loadHosts()
        guard updated.selectedId != host.id, updated.select(id: host.id) else { return }
        PairingStore.saveHosts(updated)
        LastLinkStore.clear()
        reload()
    }

    private func delete(_ host: HostIdentity) {
        PairingStore.deleteHost(id: host.id)
        LastLinkStore.clear()
        reload()
    }

    private func reload() {
        selection = PairingStore.loadHosts()
        isPaired = PairingStore.hasHost
    }
}
