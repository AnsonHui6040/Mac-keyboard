import RemoteKeyboardCore
import SwiftUI

@main
struct MacReceiverApp: App {
    // Plain stored properties, not @StateObject: the App value observes nothing, so a @Published change (the countdown
    // tick, a focus snapshot) never re-evaluates this body or redraws the status item. `init` runs once and the App value
    // keeps every service alive; only ReceiverPanel observes them.
    private let central: ReceiverBLECentral
    private let security: ReceiverSecurity
    private let loginItem: LoginItem
    private let focus: FocusMonitor
    private let testInsert: TestInsertController
    private let coordinator: ReceiverCoordinator
    private let notice: InputSourceNotice
    private let pointer: PointerReceiver
    #if DEBUG
    private let burstVerifier = BurstVerifier()
    private let measurement: MeasurementEcho
    #endif
    private let pipeline: EventPipeline

    /// The unit tests are hosted by this app. They build the objects they need themselves, so the host must not run
    /// the live wiring (focus polling, BLE arming, login item) or it could scan and inject during `xcodebuild test`.
    static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    init() {
        let loginItem = LoginItem()
        let focus = FocusMonitor()
        // One switcher, so the menu test and the BLE pipeline share the same serialization gate.
        let switcher = InputSourceSwitcher(
            controller: TISInputSourceController(),
            composition: AXCompositionAdapter(element: { [weak focus] in focus?.focusedElement }),
            settle: { try? await Task.sleep(for: .seconds($0)) }
        )
        let notice = InputSourceNotice()
        // This Mac's identity decides which UUID is scanned for, so the store is read before the central exists. The pair key
        // of protocol v3 cannot be used any more: it is removed on every launch (a no-op once it is gone), which is also
        // what turns an upgraded Mac back to unpaired.
        // The unit-test host keeps its identity in a temporary directory, so running the tests never writes to the real one.
        let store = MacPairingStore(
            directory: Self.isRunningUnitTests
                ? FileManager.default.temporaryDirectory.appendingPathComponent("RemoteKeyboardReceiverTestHost", isDirectory: true)
                : MacPairingStore.defaultDirectory)
        if !Self.isRunningUnitTests { store.removeLegacyKey() }
        let central = ReceiverBLECentral(hostId: store.loadHost().id)
        // Reads the stored phones when a keyboard connects, or from `refreshPairedState()` below.
        let security = ReceiverSecurity(central: central, store: store)
        // No file is touched until the first ping arrives; the unit-test host never receives one.
        let reconnectLog = ReconnectLog(fileURL: ReconnectLog.defaultFileURL)
        let pipeline = EventPipeline(
            snapshot: { [weak focus] in await focus?.refreshNow() },
            switcher: switcher,
            injector: TextInjector(),
            sendAck: { [weak security] ack in security?.send(.ack(ack)) },
            noteValidEvent: { [weak central] in central?.noteEvent() },
            onPing: { shown, connected in reconnectLog.record(shownAtMs: shown, connectedAtMs: connected) },
            onInputSourceRestore: { [weak notice] in notice?.report(restoredOK: $0) }
        )
        // The touchpad: packets of the `0x03` route go to it, its grant goes into the status, and every valid packet keeps the
        // receiving session going. Nothing is posted before the keyboard opens the channel with the current grant.
        let pointer = PointerReceiver(output: PointerInjector(), noteActivity: { [weak central] in central?.noteEvent() })
        central.pointerHandler = { [weak pointer] in pointer?.handle($0) }
        let coordinator = ReceiverCoordinator(
            focus: focus, central: central, security: security, pipeline: pipeline, pointer: pointer)
        if !Self.isRunningUnitTests {
            loginItem.applyDefaultIfNeeded()
            security.refreshPairedState()
            coordinator.start()
            notice.startObserving()
            focus.start()
            // Quitting from the menu: an authenticated keyboard hears a goodbye before the connection goes away with the
            // process. Best effort; it holds the run loop for at most about half a second.
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { [weak central, weak pointer] _ in
                MainActor.assumeIsolated {
                    pointer?.shutdown()
                    central?.prepareForTermination()
                }
            }
        }
        #if DEBUG
        // TP1 measurement: answers the iPhone's encrypted probes while 「量測模式」 is on. Memory only; the mode is off after
        // every launch unless `-rkMeasureMode YES` is passed, which also starts receiving.
        let measurement = MeasurementEcho(
            write: { [weak central] in central?.sendMeasure($0) ?? false },
            cursor: MeasureCursorMover(), flash: MeasureFlashWindow(), csv: MeasureCSVFile(fileURL: MeasureCSVFile.defaultFileURL),
            noteActivity: { [weak central] in central?.noteEvent() })
        measurement.connect(central: central, security: security)
        coordinator.measureMode = { [weak measurement] in measurement?.isMeasureMode ?? false }
        measurement.onModeChange = { [weak coordinator] in coordinator?.sendStatus() }
        coordinator.measureTextArrived = { [weak measurement] in measurement?.noteText($0) }
        if !Self.isRunningUnitTests, UserDefaults.standard.bool(forKey: "rkMeasureMode") {
            measurement.setMeasureMode(true)
            central.startReceiving()
        }
        self.measurement = measurement
        #endif
        self.pipeline = pipeline
        self.central = central
        self.security = security
        self.loginItem = loginItem
        self.focus = focus
        self.testInsert = TestInsertController(focus: focus, switcher: switcher, notice: notice)
        self.notice = notice
        self.pointer = pointer
        self.coordinator = coordinator
    }

    var body: some Scene {
        MenuBarExtra("Remote Keyboard", systemImage: "keyboard") {
            #if DEBUG
            ReceiverPanel(
                central: central, focus: focus, testInsert: testInsert, loginItem: loginItem, security: security,
                notice: notice, pointer: pointer, burstVerifier: burstVerifier, measurement: measurement)
            #else
            ReceiverPanel(
                central: central, focus: focus, testInsert: testInsert, loginItem: loginItem, security: security,
                notice: notice, pointer: pointer)
            #endif
        }
        .menuBarExtraStyle(.window)
        Window("使用教學", id: MacTutorialWindow.id) {
            MacTutorialView()
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

enum ReceiverMenu {
    /// 「剩餘接收時間 mm:ss」 while armed, 「待命」 otherwise.
    static func remainingText(_ seconds: TimeInterval?) -> String {
        guard let seconds else { return "待命" }
        let total = Int(seconds.rounded(.up))
        return String(format: "剩餘接收時間 %02d:%02d", total / 60, total % 60)
    }
}
