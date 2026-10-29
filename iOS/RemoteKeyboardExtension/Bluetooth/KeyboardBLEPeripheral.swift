import CoreBluetooth
import Foundation
import RemoteKeyboardCore

/// Adapter between the Core `KeyboardLinkStateMachine` and CoreBluetooth.
/// The keyboard extension advertises while visible; the Mac Receiver is the central.
///
/// Exactly one instance and one `CBPeripheralManager` exist per extension process. The system can create several
/// keyboard view controllers; each one claims this peripheral when it appears, and only the latest claimant may
/// tear the link down. Two managers publishing the same service made the Mac subscribe to a copy nobody was watching.
@MainActor
final class KeyboardBLEPeripheral: NSObject {
    static let shared = KeyboardBLEPeripheral()

    private var onStateChange: ((KeyboardLinkState) -> Void)?
    /// Every decoded message the Receiver wrote to `control`, after the peripheral's own state is updated.
    private var onControl: ((ControlMessage) -> Void)?
    /// A short user-facing note, for example when a key could not be sent.
    private var onNote: ((String) -> Void)?

    private var ownership = PeripheralOwnership<UUID>()
    /// The service add in flight. Only its own `didAdd` may advance the link state machine.
    private var pendingService = PendingServiceTracker<ObjectIdentifier>()
    /// Held so the pending service's identity cannot be reused by a later allocation while it is in flight.
    private var pendingServiceObject: CBMutableService?

    private var machine = KeyboardLinkStateMachine()
    private var manager: CBPeripheralManager?
    private var eventCharacteristic: CBMutableCharacteristic?

    // Send path. All of this belongs to one keyboard appearance and is reset when it starts or ends.
    private var sessionId = UUID()
    private var seq: UInt64 = 0
    private var queue = NotifyQueue()
    private var subscribedCentral: CBCentral?
    private(set) var latestStatus: ReceiverStatus?

    private static let serviceID = CBUUID(string: GATTServiceSpec.Link.serviceUUID)
    private static let eventID = CBUUID(string: GATTServiceSpec.Link.eventUUID)
    private static let controlID = CBUUID(string: GATTServiceSpec.Link.controlUUID)

    var linkState: KeyboardLinkState { machine.state }

    /// Remote keys are accepted only with a connected link, a subscribed central and a Receiver that says it is ready.
    var isRemoteReady: Bool {
        machine.state == .connected && subscribedCentral != nil && latestStatus?.ready == true
    }

    private override init() { super.init() }

    /// A controller that no longer owns the peripheral never sends.
    func isRemoteReady(for owner: UUID) -> Bool { ownership.isOwner(owner) && isRemoteReady }

    /// `owner` takes the callbacks and feeds `.appeared`. A claim by a new owner starts a new session (id, seq,
    /// queue) but keeps a live subscription, so a replacement controller does not drop an established link.
    func appear(
        owner: UUID, hasFullAccess: Bool,
        onStateChange: @escaping (KeyboardLinkState) -> Void,
        onControl: @escaping (ControlMessage) -> Void,
        onNote: @escaping (String) -> Void
    ) {
        let hadOwner = ownership.owner != nil
        if ownership.claim(owner) {
            KeyboardLifecycleLog.note("owner changed to \(owner.uuidString.prefix(8)) hadPrevious=\(hadOwner)")
            if hadOwner { startSession() }
        }
        self.onStateChange = onStateChange
        self.onControl = onControl
        self.onNote = onNote
        // Without Full Access no CBPeripheralManager is created at all.
        if hasFullAccess && manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: nil)
            KeyboardLifecycleLog.note("manager created")
        }
        feed(.appeared(hasFullAccess: hasFullAccess))
    }

    /// Honored only for the current owner; a stale controller's late disappear must not tear down the new owner's link.
    func disappear(owner: UUID) {
        guard ownership.isOwner(owner) else {
            KeyboardLifecycleLog.note("disappear ignored for stale \(owner.uuidString.prefix(8))")
            return
        }
        feed(.disappeared)
        endSession()
        ownership.release(owner)
        onStateChange = nil
        onControl = nil
        onNote = nil
    }

    /// A controller is going away. Same as a disappear when it is still the owner, otherwise nothing.
    func release(owner: UUID) {
        guard ownership.isOwner(owner) else { return }
        KeyboardLifecycleLog.note("owner released by deinit \(owner.uuidString.prefix(8))")
        disappear(owner: owner)
    }

    /// A fresh id, seq from 1 and nothing queued.
    private func startSession() {
        sessionId = UUID()
        seq = 0
        queue.removeAll()
    }

    /// Ends a keyboard appearance: the next one is a new peripheral session, with no stale subscription or status.
    private func endSession() {
        startSession()
        subscribedCentral = nil
        latestStatus = nil
        clearPendingService()
    }

    private func clearPendingService() {
        pendingService.clear()
        pendingServiceObject = nil
    }

    // MARK: Sending

    /// Encodes one semantic key and sends it, or queues it until the transmit queue has room.
    /// Only kind and length are logged.
    func send(_ kind: EventKind) {
        guard let central = subscribedCentral else { return }
        let event = KeyboardEvent(
            protocolVersion: KeyboardEvent.currentVersion, eventId: UUID(), sessionId: sessionId,
            seq: seq + 1, focusEpoch: latestStatus?.focusEpoch, kind: kind)
        let frame: Data
        do {
            frame = try EventCodec.encode(event, maxBytes: central.maximumUpdateValueLength)
        } catch {
            // The router already accepted this key, so say what happened instead of dropping it silently.
            let tooLarge: Bool
            if case EventCodecError.tooLarge = error { tooLarge = true } else { tooLarge = false }
            if let (key, length) = Self.diagnosticKey(kind) {
                DiagnosticEvent.keyDropped(kind: key, utf8Length: length, reason: tooLarge ? .tooLarge : .encodeFailed).log()
            }
            onNote?(tooLarge ? "事件過大，未送出" : "事件編碼失敗，未送出")
            return
        }
        seq += 1
        queue.enqueue(frame)
        if let (key, length) = Self.diagnosticKey(kind) {
            DiagnosticEvent.keySent(kind: key, utf8Length: length).log()
        }
        drain()
    }

    /// Hands queued frames to CoreBluetooth in order. A `false` from `updateValue` means the transmit queue is full;
    /// the rest waits for `peripheralManagerIsReady(toUpdateSubscribers:)`.
    private func drain() {
        guard let manager, let eventCharacteristic, let central = subscribedCentral else { return }
        queue.drain { frame in
            manager.updateValue(frame, for: eventCharacteristic, onSubscribedCentrals: [central])
        }
    }

    private static func diagnosticKey(_ kind: EventKind) -> (DiagnosticKeyKind, Int)? {
        switch kind {
        case .text(let text): (.text, text.utf8.count)
        case .backspace: (.backspace, 0)
        case .returnKey: (.return, 0)
        case .ping: nil
        }
    }

    private func feed(_ input: KeyboardLinkInput) {
        let before = machine.state
        let effects = machine.handle(input)
        for effect in effects { perform(effect) }
        if machine.state != before || input == .disappeared { onStateChange?(machine.state) }
    }

    private func perform(_ effect: KeyboardLinkEffect) {
        guard let manager else { return }
        switch effect {
        case .addService:
            let event = CBMutableCharacteristic(
                type: Self.eventID, properties: [.notify], value: nil, permissions: [])
            let control = CBMutableCharacteristic(
                type: Self.controlID, properties: [.write], value: nil, permissions: [.writeable])
            let service = CBMutableService(type: Self.serviceID, primary: true)
            service.characteristics = [event, control]
            eventCharacteristic = event
            // One manager must never hold two copies of the service.
            manager.removeAllServices()
            KeyboardLifecycleLog.note("removeAllServices before add")
            pendingServiceObject = service
            pendingService.begin(ObjectIdentifier(service))
            manager.add(service)
            KeyboardLifecycleLog.note("addService")
        case .startAdvertising:
            manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID]])
        case .stopAdvertising:
            manager.stopAdvertising()
        case .removeServices:
            clearPendingService()
            manager.removeAllServices()
            KeyboardLifecycleLog.note("removeAllServices")
            eventCharacteristic = nil
            queue.removeAll()
        }
    }

    private static func map(_ state: CBManagerState) -> PeripheralPower {
        switch state {
        case .poweredOn: .poweredOn
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        default: .unknown
        }
    }
}

extension KeyboardBLEPeripheral: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        feed(.power(Self.map(peripheral.state)))
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        // A completion for any service but the one in flight belongs to an earlier appearance and is dropped.
        guard pendingService.accept(ObjectIdentifier(service)) else {
            KeyboardLifecycleLog.note("stale didAdd ignored ok=\(error == nil)")
            return
        }
        pendingServiceObject = nil
        feed(.serviceAdded(ok: error == nil))
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        feed(.advertisingStarted(ok: error == nil))
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == Self.eventID else { return }
        subscribedCentral = central
        DiagnosticEvent.centralSubscribed(maxUpdateLength: central.maximumUpdateValueLength).log()
        KeyboardLifecycleLog.note("subscribed maxUpdateValueLength=\(central.maximumUpdateValueLength)")
        feed(.subscribed)
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == Self.eventID else { return }
        KeyboardLifecycleLog.note("unsubscribed maxUpdateValueLength=\(central.maximumUpdateValueLength)")
        // Keys typed for the old connection are not replayed into a later one.
        subscribedCentral = nil
        latestStatus = nil
        queue.removeAll()
        feed(.unsubscribed)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        drain()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        // Prepared (long) writes arrive as pieces with offsets; the payload is the pieces in offset order.
        let pieces = requests.filter { $0.characteristic.uuid == Self.controlID }.sorted { $0.offset < $1.offset }
        var payload = Data()
        for piece in pieces { payload.append(piece.value ?? Data()) }
        guard !pieces.isEmpty, let message = try? ControlCodec.decode(payload) else {
            peripheral.respond(to: first, withResult: .invalidAttributeValueLength)
            return
        }
        peripheral.respond(to: first, withResult: .success)
        switch message {
        case .status(let status):
            latestStatus = status
        case .ack(let ack):
            DiagnosticEvent.ackReceived(ack.result).log()
        }
        onControl?(message)
    }
}

extension KeyboardBLEPeripheral: @preconcurrency RemoteEventSink {
    func enqueue(_ kind: EventKind) { send(kind) }
}
