import CoreBluetooth
import CryptoKit
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

    /// Identifies a message across its frames. Never reset, not even by a new session: a session start does not
    /// always break the link, so ids stay unique across sessions on the same link. Wraps at 65,536.
    private var messageId: UInt16 = 0

    // Send path. All of this belongs to one keyboard appearance and is reset when it starts or ends.
    /// Builds each event (session id, seq, epoch) and counts the keys the Receiver has not answered yet.
    private var sender = EventSender(sessionId: UUID())
    private var queue = NotifyQueue()
    private var subscribedCentral: CBCentral?
    /// Which central the handshake belongs to. Anything else that subscribes or writes is ignored once it is authenticated.
    private var binding = CentralBinding()
    private(set) var latestStatus: ReceiverStatus?

    /// The pair key as of the last appearance or connection; `nil` when this iPhone is not paired (or the Extension has
    /// no Full Access and cannot read the Keychain).
    private var pairKey: SymmetricKey?
    /// One per Mac connection, with its own nonce. Events leave only once it `canSendEvents`, and only sealed.
    private var handshake: PhoneHandshake?

    // Reconnect timing of the current appearance, and the one probe sent for it.
    private var tracker = ReconnectTracker()
    private var pingEventId: UUID?

    private static let serviceID = CBUUID(string: GATTServiceSpec.Link.serviceUUID)
    private static let eventID = CBUUID(string: GATTServiceSpec.Link.eventUUID)
    private static let controlID = CBUUID(string: GATTServiceSpec.Link.controlUUID)

    var linkState: KeyboardLinkState { machine.state }

    /// Shown-to-connected time of this appearance, once the link has connected.
    var reconnectLatencyMs: Int64? { tracker.latencyMs }

    /// Nobody owns the peripheral; a controller that is still on screen may reclaim it.
    var isVacant: Bool { ownership.isVacant }

    /// Whether this iPhone holds a pair key.
    var isPaired: Bool { pairKey != nil }

    /// Remote keys are accepted only with a connected link, a subscribed central that proved the pair key, and a Receiver
    /// that says it is ready.
    var isRemoteReady: Bool {
        machine.state == .connected && subscribedCentral != nil && handshake?.canSendEvents == true
            && latestStatus?.ready == true
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
        // The clock starts when the owning controller's appearance starts. A replacement controller or a repeated
        // appear inside a running appearance keeps the original start.
        tracker.beginIfIdle(atMs: MonotonicClock.nowMs())
        if ownership.claim(owner) {
            KeyboardLifecycleLog.note(.ownerChanged(owner: owner, hadPrevious: hadOwner))
            if hadOwner { startSession() }
        }
        self.onStateChange = onStateChange
        self.onControl = onControl
        self.onNote = onNote
        // Without Full Access no CBPeripheralManager is created at all.
        if hasFullAccess && manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: nil)
            KeyboardLifecycleLog.note(.managerCreated)
        }
        // The Keychain is read at each appearance (and again per connection) so a pairing made in the host App since the
        // last time is picked up. Without Full Access the read fails and the keyboard is simply unpaired.
        loadPairKey()
        feed(.appeared(hasFullAccess: hasFullAccess))
        // The link machine has torn the service down by now; a manager an earlier controller created must not outlive it.
        if !hasFullAccess { releaseManager() }
    }

    /// Honored only for the current owner; a stale controller's late disappear must not tear down the new owner's link.
    func disappear(owner: UUID) {
        guard ownership.isOwner(owner) else {
            KeyboardLifecycleLog.note(.staleDisappearIgnored(owner: owner))
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
        KeyboardLifecycleLog.note(.ownerReleasedByDeinit(owner: owner))
        disappear(owner: owner)
    }

    private func loadPairKey() {
        pairKey = PairingStore.loadPairKey()
        if pairKey == nil { KeyboardLifecycleLog.note(.pairKeyMissing) }
    }

    /// Tears down the peripheral manager and everything tied to it (used when Full Access is off).
    private func releaseManager() {
        guard let manager else { return }
        manager.stopAdvertising()
        manager.removeAllServices()
        manager.delegate = nil
        self.manager = nil
        eventCharacteristic = nil
        subscribedCentral = nil
        binding.clear()
        handshake = nil
        latestStatus = nil
        queue.removeAll()
        clearPendingService()
        KeyboardLifecycleLog.note(.managerReleasedNoFullAccess)
    }

    /// A fresh id, seq from 1, nothing queued and nothing awaiting an ack. While an authenticated connection is live the
    /// sender is kept: the Mac pins the first session id a connection carries and ends the connection on any other, so a
    /// replacement controller on a live link continues the same session (only its queue is cleared).
    private func startSession() {
        if handshake?.canSendEvents != true { sender = EventSender(sessionId: UUID()) }
        queue.removeAll()
    }

    /// Ends a keyboard appearance: the next one is a new peripheral session, with no stale subscription or status.
    private func endSession() {
        handshake = nil
        startSession()
        subscribedCentral = nil
        binding.clear()
        latestStatus = nil
        tracker.reset()
        pingEventId = nil
        clearPendingService()
    }

    private func clearPendingService() {
        pendingService.clear()
        pendingServiceObject = nil
    }

    // MARK: Sending

    /// Encodes one semantic key and sends it, or queues it until the transmit queue has room.
    /// Only kind and length are logged.
    @discardableResult
    func send(_ kind: EventKind) -> UUID? {
        // Nothing leaves the phone before the Mac proved the pair key, and then only sealed.
        guard let central = subscribedCentral, let current = handshake, current.canSendEvents else { return nil }
        let event = sender.make(kind, focusEpoch: latestStatus?.focusEpoch)
        let frames: [Data]
        do {
            let message = try PeripheralCodec.encode(try current.sealEvent(event))
            // Each notification carries at most the subscribed central's maximumUpdateValueLength, header included.
            frames = try FrameCodec.split(message, messageId: messageId, maxFrameBytes: central.maximumUpdateValueLength)
        } catch {
            // The router already accepted this key, so say what happened instead of dropping it silently.
            sender.unsent(event)
            let tooLarge: Bool
            switch error {
            case EventCodecError.tooLarge, is FrameError: tooLarge = true
            default: tooLarge = false
            }
            if let (key, length) = Self.diagnosticKey(kind) {
                DiagnosticEvent.keyDropped(kind: key, utf8Length: length, reason: tooLarge ? .tooLarge : .encodeFailed).log()
            }
            onNote?(tooLarge ? "事件過大，未送出" : "事件編碼失敗，未送出")
            return nil
        }
        messageId &+= 1
        // All frames of one message go into the FIFO together, so another key can never interleave with them.
        for frame in frames { queue.enqueue(frame) }
        if let (key, length) = Self.diagnosticKey(kind) {
            DiagnosticEvent.keySent(kind: key, utf8Length: length).log()
        }
        drain()
        return event.eventId
    }

    /// Notifies one handshake message (`helloReply`) in the clear, framed like any other message.
    private func transmit(_ message: PeripheralMessage) {
        guard let central = subscribedCentral,
              let payload = try? PeripheralCodec.encode(message),
              let frames = try? FrameCodec.split(payload, messageId: messageId, maxFrameBytes: central.maximumUpdateValueLength)
        else { return }
        messageId &+= 1
        for frame in frames { queue.enqueue(frame) }
        drain()
    }

    /// One `.ping` per appearance, after the link connected and the first ReceiverStatus arrived (the Receiver refuses
    /// typed events that carry no focus epoch, so the probe waits for the same condition). Not a typed key.
    private func sendPingIfDue() {
        guard subscribedCentral != nil,
              let ping = tracker.takePing(statusReceived: latestStatus != nil, linkConnected: machine.state == .connected)
        else { return }
        DiagnosticEvent.reconnectSample(shownAtMs: ping.shownAtMs, connectedAtMs: ping.connectedAtMs).log()
        pingEventId = send(.ping(shownAtMs: ping.shownAtMs, connectedAtMs: ping.connectedAtMs))
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
        // Recorded on the transition into connected only, before the status line is refreshed.
        tracker.linkChanged(from: before, to: machine.state, atMs: MonotonicClock.nowMs())
        if before == .connected, machine.state != .connected { reportLinkLost() }
        if machine.state != before || input == .disappeared { onStateChange?(machine.state) }
        sendPingIfDue()
    }

    /// The connection ended (unsubscribed, Bluetooth off, or the keyboard went away). Keys without an ack are not
    /// resent into a later connection, so the user is told how many may not have arrived.
    private func reportLinkLost() {
        queue.removeAll()
        let unconfirmed = sender.linkLost()
        guard unconfirmed > 0 else { return }
        DiagnosticEvent.keysUnconfirmed(count: unconfirmed).log()
        onNote?(StatusLine.unconfirmedText(unconfirmed))
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
            KeyboardLifecycleLog.note(.removeAllServicesBeforeAdd)
            pendingServiceObject = service
            pendingService.begin(ObjectIdentifier(service))
            manager.add(service)
            KeyboardLifecycleLog.note(.addService)
        case .startAdvertising:
            manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID]])
        case .stopAdvertising:
            manager.stopAdvertising()
        case .removeServices:
            clearPendingService()
            manager.removeAllServices()
            KeyboardLifecycleLog.note(.removeAllServices)
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
            KeyboardLifecycleLog.note(.staleDidAddIgnored(ok: error == nil))
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
        // While the bound Mac is authenticated, another central can neither take its place nor reset its handshake.
        let outcome = binding.subscribe(central.identifier, locked: handshake?.canSendEvents == true)
        guard outcome != .refused, outcome != .keptExisting else { return }
        subscribedCentral = central
        DiagnosticEvent.centralSubscribed(maxUpdateLength: central.maximumUpdateValueLength).log()
        KeyboardLifecycleLog.note(.subscribed(maxUpdateValueLength: central.maximumUpdateValueLength))
        // Every Mac connection runs its own handshake with its own nonce; a recorded reply is useless on the next one.
        loadPairKey()
        handshake = PhoneHandshake(pairKey: pairKey, phoneNonce: Pairing.randomNonce())
        KeyboardLifecycleLog.note(.handshakeStarted)
        feed(.subscribed)
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == Self.eventID else { return }
        // A central that never was the bound one leaving changes nothing.
        guard binding.unsubscribe(central.identifier) else { return }
        KeyboardLifecycleLog.note(.unsubscribed(maxUpdateValueLength: central.maximumUpdateValueLength))
        // Keys typed for the old connection are not replayed into a later one.
        subscribedCentral = nil
        handshake = nil
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
        // The ATT request is answered either way; only the bound central's bytes reach the handshake.
        guard binding.shouldAcceptWrite(from: first.central.identifier) else { return }
        if case .pairAccept = message { return }  // pairing happens in the host App, never in the keyboard
        guard var current = handshake else { return }
        let output = current.receive(message)
        handshake = current
        switch output {
        case .none:
            break
        case .send(let reply):
            transmit(reply)
        case .authenticated:
            KeyboardLifecycleLog.note(.handshakeAuthenticated)
            onStateChange?(machine.state)
        case .deliver(let inner):
            deliver(inner)
        case .failed:
            KeyboardLifecycleLog.note(.handshakeFailed)
            // An unpaired keyboard already says so in the status line; only a failed proof needs a note.
            if pairKey != nil { onNote?("配對驗證失敗") }
            onStateChange?(machine.state)
        }
    }

    /// An `ack` or `status` the Mac sent after it was authenticated (opened from `sealed`).
    private func deliver(_ message: ControlMessage) {
        switch message {
        case .status(let status):
            latestStatus = status
        case .ack(let ack):
            DiagnosticEvent.ackReceived(ack.result).log()
            sender.acknowledged(ack)
            // The probe's own ack is not a typed key, so it never reaches the status line as "Mac 已輸入".
            if ack.eventId == pingEventId {
                pingEventId = nil
                return
            }
        case .pairAccept, .hello, .auth, .authFailed, .sealed:
            return
        }
        onControl?(message)
        if case .status = message { sendPingIfDue() }
    }
}

extension KeyboardBLEPeripheral: @preconcurrency RemoteEventSink {
    func enqueue(_ kind: EventKind) { send(kind) }
}
