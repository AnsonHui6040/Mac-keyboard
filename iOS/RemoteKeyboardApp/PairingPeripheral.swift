import CoreBluetooth
import CryptoKit
import Foundation
import RemoteKeyboardCore

/// Publishes the keyboard's GATT service while the 「配對 Mac」 screen is visible, and runs one pairing attempt with the
/// Mac that connects. Nothing is published before `start()` or after `stop()`.
///
/// - Every attempt begins when the Mac subscribes and uses a new `P256.KeyAgreement.PrivateKey`; no key is ever reused.
/// - The pair key is stored only when the user taps 確認 here. Cancel, timeout, a mismatch, a lost connection or any
///   failure discards the attempt and stores nothing.
/// - Nothing is logged: not keys, not the six digits.
@MainActor
final class PairingPeripheral: NSObject, ObservableObject {
    enum Failure: Equatable {
        case bluetoothOff, bluetoothDenied, timedOut, connectionLost, mismatch, storeFailed, publishFailed
    }

    enum Phase: Equatable {
        case idle
        /// Service being published.
        case preparing
        /// Advertising; waiting for the Mac to connect.
        case waiting
        /// Keys exchanged; both people compare the digits.
        case confirming(sas: String)
        /// This iPhone's key is stored. The connection stays up so the Mac's user can still confirm; it ends when the Mac
        /// leaves, when the user taps 完成, or when the window closes.
        case confirmed
        case paired
        case failed(Failure)
    }

    @Published private(set) var phase: Phase = .idle
    /// Whole seconds left in the window, for the countdown.
    @Published private(set) var remainingSeconds: Int?

    private static let serviceID = CBUUID(string: GATTServiceSpec.Link.serviceUUID)
    private static let eventID = CBUUID(string: GATTServiceSpec.Link.eventUUID)
    private static let controlID = CBUUID(string: GATTServiceSpec.Link.controlUUID)

    private var machine = KeyboardLinkStateMachine()
    private var manager: CBPeripheralManager?
    private var eventCharacteristic: CBMutableCharacteristic?
    private var pendingService = PendingServiceTracker<ObjectIdentifier>()
    private var pendingServiceObject: CBMutableService?
    private var subscribedCentral: CBCentral?
    /// The attempt belongs to the first central that subscribed; others are ignored until it leaves.
    private var binding = CentralBinding()
    private var queue = NotifyQueue()
    private var messageId: UInt16 = 0

    private var window = PairingWindow()
    private var timerTask: Task<Void, Never>?
    private var attempt: PhonePairing?
    private var isShuttingDown = false

    // MARK: Screen lifecycle

    /// The screen appeared: open the window and publish.
    func start() {
        guard manager == nil else { return }
        window.open(now: Date())
        phase = .preparing
        manager = CBPeripheralManager(delegate: self, queue: nil)
        feed(.appeared(hasFullAccess: true))
        startTimer()
    }

    /// The screen went away (or the user left): nothing stays published and nothing is kept.
    func stop() {
        let finished: Bool
        switch phase {
        case .paired, .failed: finished = true
        case .confirmed:
            // Already stored; leaving the screen is how it ends.
            finished = true
            phase = .paired
        default: finished = false
        }
        timerTask?.cancel()
        timerTask = nil
        discardAttempt()
        shutDown()
        window.close()
        remainingSeconds = nil
        if !finished { phase = .idle }
    }

    /// 「確認」: stores the key. Only possible from the digits prompt.
    func confirm() {
        guard case .confirming = phase, let key = attempt?.pairKey, window.isOpen(at: Date()) else { return }
        guard PairingStore.savePairKey(key) == errSecSuccess else { return end(.failed(.storeFailed)) }
        // No message tells the Mac that this side confirmed, so the connection stays up until the Mac leaves.
        phase = .confirmed
    }

    /// 「完成」 after confirming: stops publishing. Tap it once the Mac has confirmed too.
    func finish() {
        guard phase == .confirmed else { return }
        end(.paired)
    }

    /// 「取消」: discards the attempt and stops publishing.
    func cancel() { stop() }

    // MARK: Attempt

    private func end(_ result: Phase) {
        timerTask?.cancel()
        timerTask = nil
        discardAttempt()
        shutDown()
        window.close()
        remainingSeconds = nil
        phase = result
    }

    private func discardAttempt() {
        attempt = nil
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = Date()
                guard self.window.isOpen(at: now) else {
                    if self.phase == .confirmed { return self.end(.paired) }
                    return self.end(.failed(.timedOut))
                }
                self.remainingSeconds = Int((self.window.remaining(at: now) ?? 0).rounded(.up))
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Publishing

    private func feed(_ input: KeyboardLinkInput) {
        for effect in machine.handle(input) { perform(effect) }
        updatePhaseFromLink()
    }

    private func updatePhaseFromLink() {
        guard !isShuttingDown else { return }
        switch (machine.state, phase) {
        case (.advertising, .preparing), (.advertising, .waiting):
            phase = .waiting
        case (.unavailable(.poweredOff), .preparing), (.unavailable(.poweredOff), .waiting):
            phase = .failed(.bluetoothOff)
        case (.unavailable(.unauthorized), .preparing), (.unavailable(.unauthorized), .waiting):
            phase = .failed(.bluetoothDenied)
        case (.failed, .preparing), (.failed, .waiting):
            phase = .failed(.publishFailed)
        default:
            break
        }
        // A failure before any attempt ends the screen's work.
        if case .failed = phase, manager != nil { end(phase) }
    }

    private func perform(_ effect: KeyboardLinkEffect) {
        guard let manager else { return }
        switch effect {
        case .addService:
            let event = CBMutableCharacteristic(type: Self.eventID, properties: [.notify], value: nil, permissions: [])
            let control = CBMutableCharacteristic(type: Self.controlID, properties: [.write], value: nil, permissions: [.writeable])
            let service = CBMutableService(type: Self.serviceID, primary: true)
            service.characteristics = [event, control]
            eventCharacteristic = event
            manager.removeAllServices()
            pendingServiceObject = service
            pendingService.begin(ObjectIdentifier(service))
            manager.add(service)
        case .startAdvertising:
            manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID]])
        case .stopAdvertising:
            manager.stopAdvertising()
        case .removeServices:
            pendingService.clear()
            pendingServiceObject = nil
            manager.removeAllServices()
            eventCharacteristic = nil
            queue.removeAll()
        }
    }

    /// Stops advertising, removes the service and lets the manager go.
    private func shutDown() {
        guard manager != nil else { return }
        isShuttingDown = true
        defer { isShuttingDown = false }
        feed(.disappeared)
        manager?.delegate = nil
        manager = nil
        subscribedCentral = nil
        binding.clear()
        eventCharacteristic = nil
        queue.removeAll()
        machine = KeyboardLinkStateMachine()
    }

    // MARK: Notify

    private func transmit(_ message: PeripheralMessage) {
        guard let central = subscribedCentral,
              let payload = try? PeripheralCodec.encode(message),
              let frames = try? FrameCodec.split(payload, messageId: messageId, maxFrameBytes: central.maximumUpdateValueLength)
        else { return end(.failed(.connectionLost)) }
        messageId &+= 1
        for frame in frames { queue.enqueue(frame) }
        drain()
    }

    private func drain() {
        guard let manager, let eventCharacteristic, let central = subscribedCentral else { return }
        queue.drain { frame in
            manager.updateValue(frame, for: eventCharacteristic, onSubscribedCentrals: [central])
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

extension PairingPeripheral: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let power = Self.map(peripheral.state)
        if power != .poweredOn {
            // No unsubscribe is reliably reported when the radio goes away: the connection and any attempt on it are gone.
            binding.powerChanged(power)
            subscribedCentral = nil
            queue.removeAll()
            if phase == .confirmed { return end(.paired) }
            if attempt != nil { return end(.failed(.connectionLost)) }
        }
        feed(.power(power))
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard pendingService.accept(ObjectIdentifier(service)) else { return }
        pendingServiceObject = nil
        feed(.serviceAdded(ok: error == nil))
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        feed(.advertisingStarted(ok: error == nil))
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.eventID, phase == .waiting else { return }
        guard binding.subscribe(central.identifier, locked: true) == .bound else { return }
        subscribedCentral = central
        feed(.subscribed)
        // A new attempt: a key nobody has seen, committed to before the Mac's key is known.
        let pairing = PhonePairing(privateKey: P256.KeyAgreement.PrivateKey())
        attempt = pairing
        transmit(pairing.offer)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard characteristic.uuid == Self.eventID, binding.unsubscribe(central.identifier) else { return }
        subscribedCentral = nil
        queue.removeAll()
        // The Mac ended the connection (cancel, timeout, or its own failure). An unfinished attempt is gone.
        if phase == .confirmed {
            end(.paired)
            return
        }
        var attemptRunning = attempt != nil
        if case .confirming = phase { attemptRunning = true }
        if attemptRunning {
            end(.failed(.connectionLost))
        } else {
            feed(.unsubscribed)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        drain()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        let pieces = requests.filter { $0.characteristic.uuid == Self.controlID }.sorted { $0.offset < $1.offset }
        var payload = Data()
        for piece in pieces { payload.append(piece.value ?? Data()) }
        guard !pieces.isEmpty, let message = try? ControlCodec.decode(payload) else {
            peripheral.respond(to: first, withResult: .invalidAttributeValueLength)
            return
        }
        peripheral.respond(to: first, withResult: .success)
        guard binding.shouldAcceptWrite(from: first.central.identifier) else { return }
        // Only the Mac's `pairAccept` matters here. Its `hello` (it may hold an older pairing) is not for this screen.
        guard phase != .confirmed, case .pairAccept = message, var pairing = attempt else { return }
        let output = pairing.receive(message)
        attempt = pairing
        switch output {
        case .send(let reveal):
            transmit(reveal)
            if let sas = pairing.sas { phase = .confirming(sas: sas) }
        case .failed:
            end(.failed(.mismatch))
        case .none:
            break
        }
    }
}
