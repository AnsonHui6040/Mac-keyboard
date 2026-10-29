import CoreBluetooth
import Foundation
import OSLog
import RemoteKeyboardCore

/// Seam over the CoreBluetooth side so session and link wiring can be tested without hardware.
@MainActor
protocol CentralDriving: AnyObject {
    func startScan()
    func stopScan()
    func connect(_ id: UUID)
    func discover(_ id: UUID)
    func cancel(_ id: UUID)
}

/// Resident BLE central. Idle until a receive session is armed, then looks for the keyboard peripheral.
@MainActor
final class ReceiverBLECentral: ObservableObject {
    static let idleTimeoutKey = "rk.idleTimeoutSeconds"
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard.receiver", category: "link")

    @Published private(set) var linkState: ReceiverLinkState = .idle
    @Published private(set) var readyMilliseconds: Int?
    @Published private(set) var isArmed = false
    @Published private(set) var deadline: Date?
    /// Refreshed once a second while armed so the countdown stays current.
    @Published private(set) var now = Date()

    private var link = ReceiverLinkStateMachine()
    private var session: ReceiverSession
    private let makeDriver: (ReceiverBLECentral) -> CentralDriving
    private let clock: () -> Date
    private var driver: CentralDriving?
    private var idleTimer: Timer?
    private var connectTimer: Timer?
    private var tickTimer: Timer?
    private var discoveredAt: ContinuousClock.Instant?

    init(
        defaults: UserDefaults = .standard,
        clock: @escaping () -> Date = Date.init,
        makeDriver: @escaping (ReceiverBLECentral) -> CentralDriving = { CoreBluetoothDriver(owner: $0) }
    ) {
        let override = defaults.double(forKey: Self.idleTimeoutKey)
        session = ReceiverSession(idleTimeout: override > 0 ? override : ReceiverSession.idleTimeout)
        self.clock = clock
        self.makeDriver = makeDriver
    }

    var linkLabel: String {
        if case .ready = linkState, let readyMilliseconds {
            return "Link: ready (\(readyMilliseconds) ms)"
        }
        return "Link: \(linkState.name)"
    }

    var remainingSeconds: TimeInterval? {
        guard isArmed, let deadline else { return nil }
        return max(0, deadline.timeIntervalSince(clock()))
    }

    // MARK: Session

    func startReceiving() { handleSession(.manualStart) }
    func stopReceiving() { handleSession(.manualStop) }
    /// Called for every `event` notification; extends the idle deadline.
    func noteEvent() { handleSession(.eventReceived) }

    func handleSession(_ input: ReceiverSessionInput) {
        let effects = session.handle(input, now: clock())
        isArmed = session.isArmed
        deadline = session.deadline
        now = clock()
        for effect in effects {
            switch effect {
            case .arm:
                if driver == nil { driver = makeDriver(self) }
                startTicking()
                handleLink(.start)
            case .disarm:
                stopTicking()
                idleTimer?.invalidate()
                idleTimer = nil
                handleLink(.stop)
            case .scheduleTimeout(let at):
                scheduleIdleTimeout(at: at)
            }
        }
    }

    /// Common modes keep timers firing while the menu bar menu is open (run loop in `.eventTracking`).
    private static func makeTimer(
        _ interval: TimeInterval, repeats: Bool, _ fire: @escaping @MainActor () -> Void
    ) -> Timer {
        CommonModeTimer.make(interval, repeats: repeats, fire)
    }

    private func scheduleIdleTimeout(at date: Date) {
        idleTimer?.invalidate()
        let interval = max(0, date.timeIntervalSince(clock()))
        idleTimer = Self.makeTimer(interval, repeats: false) { [weak self] in self?.handleSession(.timerFired) }
    }

    private func startTicking() {
        tickTimer?.invalidate()
        tickTimer = Self.makeTimer(1, repeats: true) { [weak self] in self?.now = self?.clock() ?? Date() }
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    // MARK: Link

    func handleLink(_ input: ReceiverLinkInput) {
        let before = link.state
        if case .discovered = input { discoveredAt = .now }
        let effects = link.handle(input)
        let after = link.state
        linkState = after
        if after != before { record(after) }
        for effect in effects { apply(effect) }
        if after != before, case .ready = after { handleSession(.linkReady) }
    }

    private func record(_ state: ReceiverLinkState) {
        var ms: Int?
        if let discoveredAt {
            let d = ContinuousClock.now - discoveredAt
            ms = Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
        }
        switch state {
        case .ready: readyMilliseconds = ms
        case .scanning, .idle, .unavailable: readyMilliseconds = nil; discoveredAt = nil
        default: break
        }
        Self.log.info("state \(state.name, privacy: .public) \(ms ?? -1, privacy: .public) ms")
    }

    private func apply(_ effect: ReceiverLinkEffect) {
        switch effect {
        case .startScan: driver?.startScan()
        case .stopScan: driver?.stopScan()
        case .connect(let id): driver?.connect(id)
        case .discover(let id): driver?.discover(id)
        case .cancel(let id): driver?.cancel(id)
        case .startConnectTimeout(let seconds):
            connectTimer?.invalidate()
            connectTimer = Self.makeTimer(seconds, repeats: false) { [weak self] in self?.handleLink(.connectTimeout) }
        case .cancelConnectTimeout:
            connectTimer?.invalidate()
            connectTimer = nil
        }
    }
}

/// CoreBluetooth implementation. Reports everything back to the owner as `ReceiverLinkInput`.
@MainActor
final class CoreBluetoothDriver: NSObject, CentralDriving {
    private static let service = CBUUID(string: GATTServiceSpec.Link.serviceUUID)
    private static let event = CBUUID(string: GATTServiceSpec.Link.eventUUID)
    private static let control = CBUUID(string: GATTServiceSpec.Link.controlUUID)

    private weak var owner: ReceiverBLECentral?
    private var manager: CBCentralManager?
    /// Strong references; CoreBluetooth drops peripherals that nobody retains.
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var active: UUID?

    init(owner: ReceiverBLECentral) {
        self.owner = owner
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    func startScan() {
        guard let manager, manager.state == .poweredOn else { return }
        manager.scanForPeripherals(withServices: [Self.service])
    }

    func stopScan() {
        manager?.stopScan()
    }

    func connect(_ id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        active = id
        peripheral.delegate = self
        manager?.connect(peripheral)
    }

    func discover(_ id: UUID) {
        peripherals[id]?.discoverServices([Self.service])
    }

    func cancel(_ id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        if active == id { active = nil }
        manager?.cancelPeripheralConnection(peripheral)
    }

    private static func power(_ state: CBManagerState) -> CentralPower {
        switch state {
        case .poweredOn: .poweredOn
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        case .unknown, .resetting: .unknown
        @unknown default: .unknown
        }
    }

    private func disconnected(_ peripheral: CBPeripheral) {
        // A stale callback for a connection we already cancelled must not tear down a new attempt.
        guard active == peripheral.identifier, peripheral.state == .disconnected else { return }
        owner?.handleLink(.disconnected(peripheral.identifier))
    }
}

extension CoreBluetoothDriver: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        owner?.handleLink(.power(Self.power(central.state)))
    }

    func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any], rssi RSSI: NSNumber
    ) {
        peripherals[peripheral.identifier] = peripheral
        owner?.handleLink(.discovered(peripheral.identifier))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        owner?.handleLink(.connected(peripheral.identifier))
    }

    func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        disconnected(peripheral)
    }

    func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        disconnected(peripheral)
    }
}

extension CoreBluetoothDriver: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            return invalidated(peripheral)
        }
        peripheral.discoverCharacteristics([Self.event, Self.control], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        guard error == nil, let event = service.characteristics?.first(where: { $0.uuid == Self.event }) else {
            return invalidated(peripheral)
        }
        peripheral.setNotifyValue(true, for: event)
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard characteristic.uuid == Self.event else { return }
        if error == nil, characteristic.isNotifying {
            owner?.handleLink(.linkReady(peripheral.identifier))
        } else {
            invalidated(peripheral)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        if invalidatedServices.contains(where: { $0.uuid == Self.service }) { invalidated(peripheral) }
    }

    func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard error == nil, characteristic.uuid == Self.event else { return }
        owner?.noteEvent()
    }

    private func invalidated(_ peripheral: CBPeripheral) {
        guard active == peripheral.identifier else { return }
        owner?.handleLink(.serviceInvalidated(peripheral.identifier))
    }
}
