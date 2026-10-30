import RemoteKeyboardCore
import SwiftUI

@main
struct MacReceiverApp: App {
    @StateObject private var central: ReceiverBLECentral
    @StateObject private var loginItem: LoginItem
    @StateObject private var focus: FocusMonitor
    @StateObject private var testInsert: TestInsertController
    @StateObject private var coordinator: ReceiverCoordinator
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
        let central = ReceiverBLECentral()
        // No file is touched until the first ping arrives; the unit-test host never receives one.
        let reconnectLog = ReconnectLog(fileURL: ReconnectLog.defaultFileURL)
        let pipeline = EventPipeline(
            snapshot: { [weak focus] in focus?.refreshNow() },
            switcher: switcher,
            injector: TextInjector(),
            sendAck: { [weak central] ack in central?.send(.ack(ack)) },
            noteValidEvent: { [weak central] in central?.noteEvent() },
            onPing: { shown, connected in reconnectLog.record(shownAtMs: shown, connectedAtMs: connected) }
        )
        let coordinator = ReceiverCoordinator(focus: focus, central: central, pipeline: pipeline)
        if !Self.isRunningUnitTests {
            loginItem.applyDefaultIfNeeded()
            coordinator.start()
            focus.start()
        }
        self.pipeline = pipeline
        _central = StateObject(wrappedValue: central)
        _loginItem = StateObject(wrappedValue: loginItem)
        _focus = StateObject(wrappedValue: focus)
        _testInsert = StateObject(wrappedValue: TestInsertController(focus: focus, switcher: switcher))
        _coordinator = StateObject(wrappedValue: coordinator)
    }

    var body: some Scene {
        MenuBarExtra("Remote Keyboard", systemImage: "keyboard") {
            ReceiverPanel(central: central, focus: focus, testInsert: testInsert, loginItem: loginItem)
        }
        .menuBarExtraStyle(.window)
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
