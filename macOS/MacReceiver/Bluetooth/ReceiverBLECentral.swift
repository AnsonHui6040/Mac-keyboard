import CoreBluetooth
import Foundation
import OSLog
import RemoteKeyboardCore

/// Seam over the CoreBluetooth side so session and link wiring can be tested without hardware.
@MainActor
protocol CentralDriving: AnyObject {
    /// Scans for these advertised service UUIDs, reporting every packet (duplicates allowed). Starting again while a scan runs
    /// replaces its conditions.
    func startScan(services: [UUID])
    func stopScan()
    func connect(_ id: UUID)
    func discover(_ id: UUID)
    func cancel(_ id: UUID)
    /// Drops everything held for `id` without touching the radio (used when Bluetooth is not powered on).
    func forget(_ id: UUID)
    /// Write with response to the keyboard's `control` characteristic of the connected peripheral. Returns whether a write
    /// was issued; each issued write is answered by exactly one `ReceiverBLECentral.controlWriteCompleted()`.
    @discardableResult
    func writeControl(_ data: Data) -> Bool
}

/// Resident BLE central. Idle until a receive session is armed, then looks for the keyboard peripheral.
///
/// It scans for this Mac's selected UUID (docs/protocol/v4.md §1.3) and, while a pairing window is open, for the pairing UUID.
/// Which of the two a peripheral advertised in the packet that was just reported is the route of that connection
/// (`connectionRoute`): the selected route walks the handshake, the pairing route only carries pairing.
@MainActor
final class ReceiverBLECentral: ObservableObject {
    static let idleTimeoutKey = "rk.idleTimeoutSeconds"
    /// How long a deliberate disconnect waits for the goodbye's write response before it cancels anyway.
    static let goodbyeTimeout: TimeInterval = 0.5
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard.receiver", category: "link")

    @Published private(set) var linkState: ReceiverLinkState = .idle
    @Published private(set) var readyMilliseconds: Int?
    @Published private(set) var isArmed = false
    @Published private(set) var deadline: Date?
    /// Refreshed once a second while armed so the countdown stays current.
    @Published private(set) var now = Date()

    private var link: ReceiverLinkStateMachine
    private var session: ReceiverSession
    /// This Mac's selected UUID: the only service UUID scanned for outside a pairing window.
    let selectUUID: UUID
    private let pairingUUID = UUID(uuidString: GATTServiceSpec.Link.pairingAdvertUUID)!
    private var pairingScanEnabled = false
    /// How the peripheral of the connection in progress (or ready) was found. Set when it is accepted for connect.
    private(set) var connectionRoute: MacHandshake.Route = .selected
    private let makeDriver: (ReceiverBLECentral) -> CentralDriving
    private let clock: () -> Date
    private var driver: CentralDriving?
    private var idleTimer: Timer?
    private var connectTimer: Timer?
    private var tickTimer: Timer?
    private var panelVisible = false
    private let monotonicMs: () -> Int64
    private var rescanTimer: Timer?
    /// Last power state reported by CoreBluetooth. The radio is only commanded while it is on.
    private var power: CentralPower = .unknown
    /// When the peripheral that is now being connected was accepted, not merely seen.
    private var discoveredAtMs: Int64?

    /// Peripherals that failed authentication (or offered to pair outside a pairing window) in the current receiving
    /// session. They are not connected to again until the session ends: the list is emptied when receiving arms and
    /// when it disarms.
    private var skippedPeripherals: Set<UUID> = []

    /// Puts the frames of each `event` notification back into whole messages. One per connected peripheral; the
    /// central holds a single connection, and the reassembler is reset whenever that connection stops being ready.
    private var reassembler = FrameReassembler()

    /// Control writes issued and not yet answered. The goodbye is the last of them, so the cancel waits until all are answered.
    private var controlWritesInFlight = 0
    /// The peripheral whose goodbye was written and whose cancel is waiting for the write response or `goodbyeTimeout`.
    private var pendingGoodbye: UUID?
    private var goodbyeTimer: Timer?
    /// A peripheral was reported while the old connection was still closing; the scan is repeated once it is closed.
    private var discoveryDeferred = false

    /// Receives the bytes of every complete message (all of its frames), in arrival order.
    var eventHandler: (@MainActor (Data) -> Void)?
    /// Receives every `0x03` notification whole (one packet, never framed). Nothing sets it yet: the pointer channel comes later.
    var pointerHandler: (@MainActor (Data) -> Void)?
    #if DEBUG
    /// Receives every `0x7E` measurement notification whole. Debug builds only; a Release build skips such packets.
    var measureHandler: (@MainActor (Data) -> Void)?
    /// What a Release build is: tests switch the measurement route off to see that nothing is decrypted or answered.
    var measureEnabled = true
    /// Fires when a control write issued by `sendMeasure` is answered.
    var onMeasureWriteCompleted: (@MainActor () -> Void)?
    /// One entry per control write in flight, oldest first: true for a measurement reply. CoreBluetooth answers writes in the
    /// order they were issued, so the first entry belongs to the next answer.
    private var writeTags: [Bool] = []
    #endif
    /// Fires each time the link newly reaches ready (control characteristic is known by then).
    var onLinkReady: (@MainActor () -> Void)?
    /// Fires each time the link leaves ready (disconnect, invalidation, stop, idle timeout or radio off).
    var onLinkLost: (@MainActor () -> Void)?
    /// The sealed `bye` for the current connection, or `nil` when it is not authenticated. Asked once before every
    /// deliberate disconnect of a ready link.
    var goodbye: (@MainActor () -> ControlMessage?)?

    /// - Parameters:
    ///   - hostId: this Mac's id; the selected UUID is made from it.
    ///   - uptime: seconds on a monotonic clock, for how long a device stays held off after `notSelected`, a handshake timeout or
    ///     a version mismatch. Tests pass their own.
    init(
        hostId: Data,
        defaults: UserDefaults = .standard,
        clock: @escaping () -> Date = Date.init,
        monotonicMs: @escaping () -> Int64 = MonotonicClock.nowMs,
        uptime: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        makeDriver: @escaping (ReceiverBLECentral) -> CentralDriving = { CoreBluetoothDriver(owner: $0) }
    ) {
        let override = defaults.double(forKey: Self.idleTimeoutKey)
        session = ReceiverSession(idleTimeout: override > 0 ? override : ReceiverSession.idleTimeout)
        link = ReceiverLinkStateMachine(now: uptime)
        selectUUID = SelectUUID.make(hostId: hostId)
        self.clock = clock
        self.monotonicMs = monotonicMs
        self.makeDriver = makeDriver
    }

    /// Plain wording for the panel, Taiwan Traditional Chinese. The reason a radio is unusable is `linkReason`.
    var linkLabel: String {
        switch linkState {
        case .idle: "尚未開始接收"
        case .unavailable: "無法接收"
        case .scanning: "未連線，正在尋找 iPhone"
        case .connecting, .discovering: "正在連線 iPhone"
        case .ready: "已連線"
        }
    }

    /// Why the radio cannot be used right now; `nil` when it can.
    var linkReason: String? { linkState.reasonText }

    /// `true` while the radio is unusable because the user has not allowed Bluetooth for this app.
    var needsBluetoothPermission: Bool { linkState == .unavailable(.unauthorized) }

    var remainingSeconds: TimeInterval? {
        guard isArmed, let deadline else { return nil }
        return max(0, deadline.timeIntervalSince(clock()))
    }

    // MARK: Session

    func startReceiving() { handleSession(.manualStart) }
    func stopReceiving() { handleSession(.manualStop) }

    /// The app is quitting: stop receiving (which says goodbye) and keep the run loop turning until the connection is
    /// cancelled, for at most about `goodbyeTimeout`. Best effort; returns at once when nothing is connected.
    func prepareForTermination() {
        stopReceiving()
        let end = Date().addingTimeInterval(Self.goodbyeTimeout + 0.2)
        while pendingGoodbye != nil, Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }
    /// Extends the idle deadline for one validly decoded event.
    func noteEvent() { handleSession(.eventReceived) }
    /// The focused Mac field became editable (D13): arms receiving, or extends it when already armed.
    func focusGainedEditable() { handleSession(.editableFocusGained) }

    /// Called by the driver for every `event` notification. The first byte decides where it goes: `0x02` is a frame of the
    /// keyboard's message, `0x03` a pointer packet, `0x7E` (Debug builds) a measurement packet. Anything else is skipped and
    /// only its first byte and length are logged. Only a `0x02` frame reaches the reassembler, so a packet between two
    /// frames of one message leaves that message alone.
    func receive(eventData: Data) {
        // Notifications only count on a ready link; anything else (a stale callback, a connection still being set up) is dropped.
        guard case .ready = link.state else { return }
        switch eventData.first {
        case CounterChannel.frameMagic?:
            receive(frame: eventData)
        case CounterChannel.Kind.pointer.magic?:
            pointerHandler?(eventData)
        #if DEBUG
        case CounterChannel.measureMagic? where measureEnabled && measureHandler != nil:
            measureHandler?(eventData)
        #endif
        default:
            let first = eventData.first.map { Int($0) } ?? -1
            Self.log.info("notification skipped first=\(first, privacy: .public) bytes=\(eventData.count, privacy: .public)")
        }
    }

    /// One `0x02` frame. Only a complete message reaches the handler; decoding and the idle deadline belong to the handler.
    private func receive(frame eventData: Data) {
        let droppedBefore = reassembler.droppedPartialMessages
        let result = reassembler.accept(eventData)
        let dropped = reassembler.droppedPartialMessages - droppedBefore
        if dropped > 0 {
            Self.log.info("partial message dropped count=\(dropped, privacy: .public) bytes=\(eventData.count, privacy: .public)")
        }
        switch result {
        case .incomplete:
            break
        case .complete(let message):
            eventHandler?(message)
        case .rejected(let error):
            Self.log.info("frame rejected \(String(describing: error), privacy: .public) bytes=\(eventData.count, privacy: .public)")
        }
    }

    /// Writes a control message with response. Dropped unless the link is ready.
    func send(_ message: ControlMessage) {
        guard case .ready = link.state, let data = try? ControlCodec.encode(message) else { return }
        if driver?.writeControl(data) == true {
            controlWritesInFlight += 1
            #if DEBUG
            writeTags.append(false)
            #endif
        }
    }

    #if DEBUG
    /// Writes an already sealed measurement reply (`0x7E`, 41 bytes) with response. Returns whether a write was issued.
    func sendMeasure(_ data: Data) -> Bool {
        guard case .ready = link.state, driver?.writeControl(data) == true else { return false }
        controlWritesInFlight += 1
        writeTags.append(true)
        return true
    }
    #endif

    /// The driver reports every answered control write (success or failure). Releases a waiting goodbye once the last
    /// write in flight is answered; CoreBluetooth answers writes in the order they were issued.
    func controlWriteCompleted() {
        controlWritesInFlight = max(0, controlWritesInFlight - 1)
        #if DEBUG
        if !writeTags.isEmpty, writeTags.removeFirst() { onMeasureWriteCompleted?() }
        #endif
        if pendingGoodbye != nil, goodbyeTimer != nil, controlWritesInFlight == 0 { finishGoodbye() }
    }

    /// Drops the connection in progress (or ready), if any, and goes back to scanning. With `skipForSession` the
    /// peripheral is also not connected to again for the rest of the receiving session.
    func disconnectCurrent(skipForSession: Bool) {
        let id: UUID
        switch link.state {
        case .connecting(let current), .discovering(let current), .ready(let current): id = current
        default: return
        }
        if skipForSession {
            skippedPeripherals.insert(id)
            Self.log.info("peripheral skipped for this receiving session")
        }
        // A service that went away is how the link machine already expresses "drop this peripheral and look again".
        endLinkDeliberately(.serviceInvalidated(id))
    }

    /// Forgets every skipped peripheral and starts a fresh scan (the driver reports a peripheral once per scan), so a
    /// phone seen before is reported again. Also ends a live connection. Does nothing while receiving is not armed.
    func restartScanning() {
        skippedPeripherals.removeAll()
        guard isArmed else { return }
        endLinkDeliberately(.stop)
        handleLink(.start)
    }

    func handleSession(_ input: ReceiverSessionInput) {
        let effects = session.handle(input, now: clock())
        isArmed = session.isArmed
        deadline = session.deadline
        now = clock()
        for effect in effects {
            switch effect {
            case .arm:
                skippedPeripherals.removeAll()
                if driver == nil { driver = makeDriver(self) }
                refreshTicking()
                handleLink(.start)
            case .disarm:
                skippedPeripherals.removeAll()
                refreshTicking()
                idleTimer?.invalidate()
                idleTimer = nil
                endLinkDeliberately(.stop)
            case .scheduleTimeout(let at):
                scheduleIdleTimeout(at: at)
            }
        }
    }

    // MARK: Scan conditions

    /// The service UUIDs scanned for now: the selected UUID, plus the pairing UUID while a pairing window is open.
    var scanServices: [UUID] { pairingScanEnabled ? [selectUUID, pairingUUID] : [selectUUID] }

    /// A pairing window opened or closed. A scan that is running is restarted at once with the new conditions; otherwise they
    /// apply to the next scan.
    func setPairingScan(_ enabled: Bool) {
        guard pairingScanEnabled != enabled else { return }
        pairingScanEnabled = enabled
        guard case .scanning = link.state else { return }
        if power == .poweredOn { driver?.stopScan() }
        driver?.startScan(services: scanServices)
    }

    /// The driver saw a peripheral. The route comes from the service UUIDs of this one packet and from nothing else: the
    /// system may remember more for the same device (docs/protocol/v4.md §1.4). A packet that names neither UUID this Mac is
    /// scanning for is ignored, and so is a pairing UUID that arrives after the window closed.
    func peripheralDiscovered(_ id: UUID, advertisedServices: [UUID]) {
        let route: MacHandshake.Route
        if advertisedServices.contains(selectUUID) {
            route = .selected
        } else if pairingScanEnabled, advertisedServices.contains(pairingUUID) {
            route = .pairing
        } else {
            return
        }
        handleLink(.discovered(id), route: route)
    }

    // MARK: Ending a connection that did not authenticate

    /// The handshake of the ready connection did not finish in time (5 seconds, docs/protocol/v4.md §6.2). Drops it without a
    /// word to the peripheral and holds this device off for a few seconds; the search for others goes on.
    func handshakeTimedOut() { endReadyLink { .handshakeTimeout($0) } }

    /// The keyboard answered `notSelected`: it types to another host. Same treatment as a handshake timeout, and no error.
    func peripheralNotSelected() { endReadyLink { .notSelected($0) } }

    /// The keyboard speaks another protocol version. With `hold` it is not connected to again for 60 seconds; without, it is only
    /// dropped (inside a pairing window it may be the phone about to pair, docs/protocol/v4.md §6.2).
    func peripheralUnsupportedVersion(hold: Bool) {
        if hold { endReadyLink { .unsupportedVersion($0) } } else { disconnectCurrent(skipForSession: false) }
    }

    private func endReadyLink(_ input: (UUID) -> ReceiverLinkInput) {
        guard case .ready(let id) = link.state else { return }
        endLinkDeliberately(input(id))
        // The state machine now waits for the disconnect of `id`. The driver forgets a peripheral it cancels, so its own
        // disconnect callback would be ignored; the disconnect is reported here instead, and the search starts again.
        if case .ready(id) = link.state { handleLink(.disconnected(id)) }
    }

    // MARK: Goodbye

    /// Ends a connection on this side's initiative. An authenticated keyboard is told first (a sealed `bye`) and the
    /// cancel waits for the write response: the phone and this Mac share an iCloud account, so the system may keep its own
    /// link up after a cancel and the keyboard would never learn that this Receiver left.
    private func endLinkDeliberately(_ input: ReceiverLinkInput) {
        beginGoodbye()
        handleLink(input)
        // A goodbye whose cancel never came (nothing to cancel after all) must not wait for a timer nobody started.
        if pendingGoodbye != nil, goodbyeTimer == nil { finishGoodbye() }
    }

    private func beginGoodbye() {
        guard case .ready(let id) = link.state, power == .poweredOn, pendingGoodbye == nil, let driver,
              let message = goodbye?(), let data = try? ControlCodec.encode(message), driver.writeControl(data)
        else { return }
        controlWritesInFlight += 1
        #if DEBUG
        writeTags.append(false)
        #endif
        pendingGoodbye = id
    }

    /// The cancel effect of a link that has a goodbye on the wire: wait for the write response, or the fallback timer.
    private func awaitGoodbyeResponse() {
        goodbyeTimer?.invalidate()
        goodbyeTimer = Self.makeTimer(Self.goodbyeTimeout, repeats: false) { [weak self] in self?.finishGoodbye() }
    }

    private func finishGoodbye() {
        guard let id = pendingGoodbye else { return }
        pendingGoodbye = nil
        goodbyeTimer?.invalidate()
        goodbyeTimer = nil
        controlWritesInFlight = 0
        #if DEBUG
        writeTags.removeAll()
        #endif
        if power == .poweredOn { driver?.cancel(id) } else { driver?.forget(id) }
        // A phone reported inside the window was ignored; the scan is repeated so the driver reports it again.
        if discoveryDeferred {
            discoveryDeferred = false
            if case .scanning = link.state { driver?.startScan(services: scanServices) }
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

    /// Whether the one-second tick is running (armed and the panel open).
    var isTicking: Bool { tickTimer != nil }

    /// The menu bar panel opened or closed. `now` only feeds the panel's countdowns, so the tick runs only while armed and
    /// visible; nothing else (idle expiry, deadlines) reads `now`, they use their own timers and `clock()`.
    func setPanelVisible(_ visible: Bool) {
        panelVisible = visible
        if visible { now = clock() }
        refreshTicking()
    }

    private func refreshTicking() {
        guard isArmed, panelVisible else {
            tickTimer?.invalidate()
            tickTimer = nil
            return
        }
        guard tickTimer == nil else { return }
        tickTimer = Self.makeTimer(1, repeats: true) { [weak self] in self?.now = self?.clock() ?? Date() }
    }

    // MARK: Link

    /// - Parameter route: for `.discovered` only: how the peripheral was found (see `peripheralDiscovered`).
    func handleLink(_ input: ReceiverLinkInput, route: MacHandshake.Route = .selected) {
        if case .discovered(let id) = input, skippedPeripherals.contains(id) { return }
        // The connection that said goodbye is still closing; connecting now could be undone by its pending cancel.
        if case .discovered = input, pendingGoodbye != nil {
            discoveryDeferred = true
            return
        }
        if case .power(let new) = input { power = new }
        let before = link.state
        let effects = link.handle(input)
        let after = link.state
        // Every packet of a scan that reports duplicates comes through here; an unchanged state must not publish.
        if linkState != after { linkState = after }
        // The clock starts only when the discovered peripheral was accepted for connect.
        if case .discovered = input, before == .scanning, case .connecting = after {
            discoveredAtMs = monotonicMs()
            connectionRoute = route
        }
        if after != before { record(after) }
        // Whatever the transition, a state with no connection in progress holds no start time.
        switch after {
        case .scanning, .idle, .unavailable: discoveredAtMs = nil
        default: break
        }
        for effect in effects { apply(effect) }
        if after != before, case .ready = after {
            reassembler.reset()
            controlWritesInFlight = 0
            #if DEBUG
            writeTags.removeAll()
            #endif
            handleSession(.linkReady)
            onLinkReady?()
        }
        if case .ready = before, after != before {
            reassembler.reset()
            onLinkLost?()
        }
    }

    private func record(_ state: ReceiverLinkState) {
        // Milliseconds since the peripheral was accepted. States without a connection in progress log -1 rather
        // than the age of an earlier connection.
        var ms: Int?
        switch state {
        case .ready:
            ms = discoveredAtMs.map { Int(monotonicMs() - $0) }
            readyMilliseconds = ms
        case .connecting, .discovering:
            ms = discoveredAtMs.map { Int(monotonicMs() - $0) }
        case .scanning, .idle, .unavailable:
            readyMilliseconds = nil
            discoveredAtMs = nil
        }
        Self.log.info("state \(state.name, privacy: .public) \(ms ?? -1, privacy: .public) ms")
    }

    private func apply(_ effect: ReceiverLinkEffect) {
        switch effect {
        case .startScan: driver?.startScan(services: scanServices)
        // CoreBluetooth is told to stop or cancel only while it is powered on; otherwise there is nothing to undo.
        case .stopScan: if power == .poweredOn { driver?.stopScan() }
        case .connect(let id): driver?.connect(id)
        case .discover(let id): driver?.discover(id)
        case .cancel(let id):
            if power != .poweredOn {
                driver?.forget(id)
            } else if pendingGoodbye == id {
                awaitGoodbyeResponse()
            } else {
                driver?.cancel(id)
            }
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

    /// - Parameter makeManager: builds the CoreBluetooth manager for this delegate. Tests pass a fake.
    init(
        owner: ReceiverBLECentral,
        makeManager: (CBCentralManagerDelegate) -> CBCentralManager = { CBCentralManager(delegate: $0, queue: nil) }
    ) {
        self.owner = owner
        super.init()
        manager = makeManager(self)
    }

    func startScan(services: [UUID]) {
        guard let manager, manager.state == .poweredOn else { return }
        // Anything but the connection in flight is stale; a fresh scan finds what is really there.
        peripherals = peripherals.filter { $0.key == active }
        // Every packet is reported, so a keyboard that changes the UUID it advertises is seen at once (docs/protocol/v4.md §1.4).
        manager.scanForPeripherals(
            withServices: services.map { CBUUID(nsuuid: $0) },
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
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

    func writeControl(_ data: Data) -> Bool {
        guard let id = active, let peripheral = peripherals[id], let control else { return false }
        guard data.count <= peripheral.maximumWriteValueLength(for: .withResponse) else {
            Self.log.error("control write dropped, length \(data.count, privacy: .public)")
            return false
        }
        peripheral.writeValue(data, for: control, type: .withResponse)
        return true
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
        // The UUIDs of this packet only. A UUID that does not fit in the packet is in the overflow area.
        let listed = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let overflow = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        let advertised = (listed + overflow).compactMap { UUID(uuidString: $0.uuidString) }
        peripherals[peripheral.identifier] = peripheral
        owner?.peripheralDiscovered(peripheral.identifier, advertisedServices: advertised)
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
        guard error == nil, characteristic.uuid == Self.event, active == peripheral.identifier,
              let data = characteristic.value else { return }
        owner?.receive(eventData: data)
    }

    func peripheral(
        _ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        // Only the active peripheral's answers count; a stale one must not release a goodbye early.
        guard characteristic.uuid == Self.control, active == peripheral.identifier else { return }
        // Success or failure, the write is answered; a waiting goodbye may now close the connection.
        owner?.controlWriteCompleted()
        guard let error else { return }
        Self.log.error("control write failed code \((error as NSError).code, privacy: .public)")
    }

    private func invalidated(_ peripheral: CBPeripheral) {
        guard active == peripheral.identifier else { return }
        owner?.handleLink(.serviceInvalidated(peripheral.identifier))
    }
}
