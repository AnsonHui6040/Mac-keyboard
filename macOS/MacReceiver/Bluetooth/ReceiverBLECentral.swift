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
    /// Drops everything held for `id` without touching the radio (used when Bluetooth is not powered on).
    func forget(_ id: UUID)
    /// Write with response to the keyboard's `control` characteristic of the connected peripheral.
    func writeControl(_ data: Data)
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
    private let monotonicMs: () -> Int64
    private var rescanTimer: Timer?
    /// Last power state reported by CoreBluetooth. The radio is only commanded while it is on.
    private var power: CentralPower = .unknown
    /// When the peripheral that is now being connected was accepted, not merely seen.
    private var discoveredAtMs: Int64?

    /// Receives the raw bytes of every `event` notification, in arrival order.
    var eventHandler: (@MainActor (Data) -> Void)?
    /// Fires each time the link newly reaches ready (control characteristic is known by then).
    var onLinkReady: (@MainActor () -> Void)?
    /// Fires each time the link leaves ready (disconnect, invalidation, stop, idle timeout or radio off).
    var onLinkLost: (@MainActor () -> Void)?

    init(
        defaults: UserDefaults = .standard,
        clock: @escaping () -> Date = Date.init,
        monotonicMs: @escaping () -> Int64 = MonotonicClock.nowMs,
        makeDriver: @escaping (ReceiverBLECentral) -> CentralDriving = { CoreBluetoothDriver(owner: $0) }
    ) {
        let override = defaults.double(forKey: Self.idleTimeoutKey)
        session = ReceiverSession(idleTimeout: override > 0 ? override : ReceiverSession.idleTimeout)
        self.clock = clock
        self.monotonicMs = monotonicMs
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
    /// Extends the idle deadline for one validly decoded event.
    func noteEvent() { handleSession(.eventReceived) }
    /// The focused Mac field became editable (D13): arms receiving, or extends it when already armed.
    func focusGainedEditable() { handleSession(.editableFocusGained) }

    /// Called by the driver for every `event` notification. Decoding and the idle deadline belong to the handler.
    func receive(eventData: Data) { eventHandler?(eventData) }

    /// Writes a control message with response. Dropped unless the link is ready.
    func send(_ message: ControlMessage) {
        guard case .ready = link.state, let data = try? ControlCodec.encode(message) else { return }
        driver?.writeControl(data)
    }

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
        if case .power(let new) = input { power = new }
        let before = link.state
        let effects = link.handle(input)
        let after = link.state
        linkState = after
        // The clock starts only when the discovered peripheral was accepted for connect.
        if case .discovered = input, before == .scanning, case .connecting = after { discoveredAtMs = monotonicMs() }
        if after != before { record(after) }
        for effect in effects { apply(effect) }
        if after != before, case .ready = after {
            handleSession(.linkReady)
            onLinkReady?()
        }
        if case .ready = before, after != before { onLinkLost?() }
    }

    private func record(_ state: ReceiverLinkState) {
        let ms = discoveredAtMs.map { Int(monotonicMs() - $0) }
        switch state {
        case .ready: readyMilliseconds = ms
        case .scanning, .idle, .unavailable: readyMilliseconds = nil; discoveredAtMs = nil
        default: break
        }
        Self.log.info("state \(state.name, privacy: .public) \(ms ?? -1, privacy: .public) ms")
    }

    private func apply(_ effect: ReceiverLinkEffect) {
        switch effect {
        case .startScan: driver?.startScan()
        // CoreBluetooth is told to stop or cancel only while it is powered on; otherwise there is nothing to undo.
        case .stopScan: if power == .poweredOn { driver?.stopScan() }
        case .connect(let id): driver?.connect(id)
        case .discover(let id): driver?.discover(id)
        case .cancel(let id):
            if power == .poweredOn { driver?.cancel(id) } else { driver?.forget(id) }
        case .startScanAfter(let seconds):
            rescanTimer?.invalidate()
            rescanTimer = Self.makeTimer(seconds, repeats: false) { [weak self] in self?.handleLink(.rescanTimer) }
        case .cancelRescanTimer:
            rescanTimer?.invalidate()
            rescanTimer = nil
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
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard.receiver", category: "link")

    private weak var owner: ReceiverBLECentral?
    private var manager: CBCentralManager?
    /// Strong references; CoreBluetooth drops peripherals that nobody retains.
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var active: UUID?
    private var control: CBCharacteristic?

    init(owner: ReceiverBLECentral) {
        self.owner = owner
        super.init()
        manager = CBCentralManager(delegate: self, queue: nil)
    }

    func startScan() {
        guard let manager, manager.state == .poweredOn else { return }
        // Anything but the connection in flight is stale; a fresh scan finds what is really there.
        peripherals = peripherals.filter { $0.key == active }
        manager.scanForPeripherals(withServices: [Self.service])
    }

    func stopScan() {
        guard let manager, manager.state == .poweredOn else { return }
        manager.stopScan()
    }

    func forget(_ id: UUID) {
        if active == id {
            active = nil
            control = nil
        }
        peripherals[id] = nil
    }

    func connect(_ id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        active = id
        control = nil
        peripheral.delegate = self
        manager?.connect(peripheral)
    }

    func discover(_ id: UUID) {
        peripherals[id]?.discoverServices([Self.service])
    }

    func cancel(_ id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        forget(id)
        guard let manager, manager.state == .poweredOn else { return }
        manager.cancelPeripheralConnection(peripheral)
    }

    func writeControl(_ data: Data) {
        guard let id = active, let peripheral = peripherals[id], let control else { return }
        guard data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            Self.log.error("control write dropped, length \(data.count, privacy: .public)")
            return
        }
        peripheral.writeValue(data, for: control, type: .withResponse)
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
        forget(peripheral.identifier)
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
        // More than one copy of the service on a peripheral means a duplicate publisher on the phone.
        let copies = peripheral.services?.filter { $0.uuid == Self.service }.count ?? 0
        Self.log.notice("discovered \(copies, privacy: .public) keyboard service(s)")
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            return invalidated(peripheral)
        }
        peripheral.discoverCharacteristics([Self.event, Self.control], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        guard error == nil,
              let event = service.characteristics?.first(where: { $0.uuid == Self.event }),
              let control = service.characteristics?.first(where: { $0.uuid == Self.control })
        else { return invalidated(peripheral) }
        // Known before notifications start, so the first status can be written the moment the link is ready.
        self.control = control
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
        guard error == nil, characteristic.uuid == Self.event, let data = characteristic.value else { return }
        owner?.receive(eventData: data)
    }

    func peripheral(
        _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard characteristic.uuid == Self.control, let error else { return }
        Self.log.error("control write failed code \((error as NSError).code, privacy: .public)")
    }

    private func invalidated(_ peripheral: CBPeripheral) {
        guard active == peripheral.identifier else { return }
        owner?.handleLink(.serviceInvalidated(peripheral.identifier))
    }
}
