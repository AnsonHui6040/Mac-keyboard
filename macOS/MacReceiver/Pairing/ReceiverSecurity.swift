import CryptoKit
import Foundation
import OSLog
import RemoteKeyboardCore

/// Everything about who may type on this Mac: the per-connection handshake, the pairing window and the pair key.
///
/// - Every keyboard connection starts with a fresh `MacHandshake` and a fresh nonce. Until the phone proved the pair key,
///   nothing but `hello` is written; afterwards every `ack`, `status` and `bye` goes out sealed (`sealControl`), and events are
///   accepted only as sealed payloads that open under this connection's session key.
/// - A plaintext event, a failed proof, a failed open, bytes that are not a message, or a second keyboard session on the
///   same connection ends in `authFailed`, a disconnect, and no reconnection to that peripheral in this receiving session.
/// - Pairing runs only inside the 120 second window the user opens from the menu. Each attempt uses a new private key.
///   The pair key is stored only when the user taps 確認 on the Mac; cancel, timeout, mismatch and any failure discard it.
///
/// Nothing here logs keys, nonces, proofs, the SAS or typed text.
@MainActor
final class ReceiverSecurity: ObservableObject {
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard.receiver", category: "security")
    static let defaultHandshakeTimeout: TimeInterval = 5

    enum PairingPhase: Equatable {
        case idle
        /// The window is open and no iPhone has started an attempt yet.
        case waiting
        /// Keys are exchanged; both people compare the six digits and confirm or cancel.
        case confirming(sas: String)
        /// This Mac's key is stored. The connection is kept so the iPhone can still confirm; it ends when the iPhone leaves,
        /// when the user taps 完成, or when the window closes.
        case confirmed
    }

    enum PairingResult: Equatable {
        case paired, cancelled, timedOut, failed, storeFailed
    }

    @Published private(set) var phase: PairingPhase = .idle
    @Published private(set) var isPaired = false
    @Published private(set) var lastResult: PairingResult?

    /// The phone proved the pair key; `auth` has been written. The first sealed status goes out from here.
    var onAuthenticated: (@MainActor () -> Void)?
    /// A verified, decrypted event of the authenticated connection.
    var onEvent: (@MainActor (KeyboardEvent) -> Void)?
    /// An authenticated payload that could not be parsed.
    var onMalformed: (@MainActor () -> Void)?
    /// The connection ended (or was dropped).
    var onLinkLost: (@MainActor () -> Void)?
    /// The counter channels of the connection, handed over once when the phone is authenticated (before `onAuthenticated`),
    /// and `nil` when that connection ends or is dropped. The receiver of the set keeps it until then.
    var onChannelSet: (@MainActor (ChannelSet?) -> Void)?

    private let central: ReceiverBLECentral
    private let store: PairKeyStoring
    private let clock: () -> Date
    private let makeNonce: @MainActor () -> Data
    private let handshakeTimeout: TimeInterval

    private var handshake: MacHandshake?
    /// The goodbye `unpair()` sealed before it dropped the handshake, for whichever disconnect happens first.
    private var farewell: ControlMessage?
    private var pin = SessionPin()
    private var handshakeTimer: Timer?

    private var window = PairingWindow()
    private var windowTimer: Timer?
    private var attempt: MacPairing?
    /// True when opening the window is what turned receiving on, so closing it turns receiving off again.
    private var armedByPairing = false

    /// Wires itself to the central's callbacks. Reads nothing from the store until `refreshPairedState()`.
    init(
        central: ReceiverBLECentral, store: PairKeyStoring, clock: @escaping () -> Date = Date.init,
        makeNonce: @escaping @MainActor () -> Data = { Pairing.randomNonce() },
        handshakeTimeout: TimeInterval = ReceiverSecurity.defaultHandshakeTimeout
    ) {
        self.central = central
        self.store = store
        self.clock = clock
        self.makeNonce = makeNonce
        self.handshakeTimeout = handshakeTimeout
        central.eventHandler = { [weak self] data in self?.receive(data) }
        central.onLinkReady = { [weak self] in self?.linkReady() }
        central.onLinkLost = { [weak self] in self?.linkLost() }
        central.goodbye = { [weak self] in self?.goodbyeMessage() }
    }

    func refreshPairedState() { isPaired = store.load() != nil }

    var isAuthenticated: Bool { handshake?.isAuthenticated ?? false }

    /// Seconds left in the pairing window, for the menu countdown; `nil` while no window is open.
    func windowRemaining(at now: Date) -> TimeInterval? { window.remaining(at: now) }

    // MARK: Writing to the keyboard

    /// Writes an `ack` or `status`. Sealed on an authenticated connection and dropped on any other: the app name never
    /// travels in the clear, and nothing but the handshake is written before the phone is verified.
    func send(_ message: ControlMessage) {
        guard let handshake, let sealed = try? handshake.sealControl(message) else { return }
        central.send(sealed)
    }

    /// The sealed `bye` to write before a deliberate disconnect; `nil` unless this connection is authenticated.
    private func goodbyeMessage() -> ControlMessage? {
        if let farewell { return farewell }
        guard let handshake, handshake.isAuthenticated else { return nil }
        return try? handshake.sealControl(.bye)
    }

    // MARK: Connection

    private func linkReady() {
        pin = SessionPin()
        let key = store.load()
        let windowOpen = window.isOpen(at: clock())
        var next = MacHandshake(pairKey: key, macNonce: makeNonce())
        // No pairing and no window: there is nobody to verify, so nobody is talked to.
        guard key != nil || windowOpen else {
            handshake = next
            failAuth()
            return
        }
        if key != nil, case .send(let hello) = next.begin() { central.send(hello) }
        handshake = next
        startHandshakeTimer()
    }

    private func linkLost() {
        handshakeTimer?.invalidate()
        handshakeTimer = nil
        handshake = nil
        pin = SessionPin()
        onChannelSet?(nil)
        // An attempt belongs to the connection it started on. A window that only waits survives a lost link. After this
        // side confirmed, the iPhone leaving is how the pairing ends.
        if phase == .confirmed {
            endPairing(.paired)
        } else if attempt != nil {
            endPairing(.failed)
        }
        onLinkLost?()
    }

    /// Fail closed: tell the peripheral, drop it, and do not connect to it again in this receiving session.
    private func failAuth() {
        handshakeTimer?.invalidate()
        handshakeTimer = nil
        handshake = nil
        onChannelSet?(nil)
        central.send(.authFailed)
        Self.log.info("authentication failed, peripheral dropped")
        // A pairing attempt dies with its connection, and the window with it. A failure on any other connection leaves
        // an open window alone.
        if attempt != nil { return endPairing(.failed) }
        central.disconnectCurrent(skipForSession: true)
    }

    private func startHandshakeTimer() {
        handshakeTimer?.invalidate()
        handshakeTimer = CommonModeTimer.make(handshakeTimeout, repeats: false) { [weak self] in self?.handshakeTimerFired() }
    }

    /// A peripheral that has not authenticated in time is dropped, unless a pairing window is open (that connection may
    /// be the iPhone that is about to pair; the window's own deadline bounds it).
    func handshakeTimerFired() {
        guard let handshake, !handshake.isAuthenticated, phase == .idle else { return }
        failAuth()
    }

    // MARK: Messages from the keyboard

    private func receive(_ data: Data) {
        guard var current = handshake else { return }
        guard let message = try? PeripheralCodec.decode(data) else { return failAuth() }
        let output = current.receive(message)
        handshake = current
        switch output {
        case .none, .send:
            break
        case .authenticated(let reply):
            handshakeTimer?.invalidate()
            handshakeTimer = nil
            central.send(reply)
            if let channels = current.takeChannelSet() {
                handshake = current
                onChannelSet?(channels)
            }
            onAuthenticated?()
        case .pairOffer, .pairReveal:
            pairingMessage(message)
        case .event(let event):
            guard pin.accept(event.sessionId) else { return failAuth() }
            onEvent?(event)
        case .malformedPayload:
            onMalformed?()
        case .authFailed:
            failAuth()
        }
    }

    // MARK: Pairing

    /// Menu 「配對新 iPhone」. Opens the 120 second window, turns receiving on if it was off, and starts a fresh scan.
    func openPairingWindow() {
        guard phase == .idle else { return }
        lastResult = nil
        window.open(now: clock())
        phase = .waiting
        armedByPairing = !central.isArmed
        if armedByPairing { central.startReceiving() } else { central.restartScanning() }
        windowTimer?.invalidate()
        windowTimer = CommonModeTimer.make(PairingWindow.duration, repeats: false) { [weak self] in self?.windowTimerFired() }
        Self.log.info("pairing window opened")
    }

    /// The window's timer. Internal so a test can move the clock and fire it.
    func windowTimerFired() {
        guard phase != .idle, !window.isOpen(at: clock()) else { return }
        endPairing(phase == .confirmed ? .paired : .timedOut)
    }

    /// 「確認」 on the Mac. Stores the pair key; only reachable from the SAS prompt, and only inside the window.
    func confirmPairing() {
        guard case .confirming = phase, let key = attempt?.pairKey else { return }
        guard window.isOpen(at: clock()) else { return endPairing(.timedOut) }
        do {
            try store.save(key)
        } catch {
            // A failed save may have removed the old key; show what the store really holds.
            refreshPairedState()
            return endPairing(.storeFailed)
        }
        isPaired = true
        lastResult = .paired
        // The connection stays up: there is no message that tells the iPhone this side confirmed, and the iPhone's user may
        // not have tapped yet. Dropping it now would make the iPhone's attempt fail.
        phase = .confirmed
    }

    /// 「完成」 after confirming: ends the window and the pairing connection. Tap it once the iPhone has confirmed too.
    func finishPairing() {
        guard phase == .confirmed else { return }
        endPairing(.paired)
    }

    /// 「取消」: discards the attempt and drops the connection. Nothing to cancel once the key is stored.
    func cancelPairing() {
        guard phase != .idle, phase != .confirmed else { return }
        endPairing(.cancelled)
    }

    /// 「解除配對」: forgets the pair key and ends any connection, which may be authenticated.
    func unpair() {
        store.delete()
        isPaired = false
        // The goodbye is sealed while the handshake still exists; whichever disconnect comes first writes it.
        farewell = goodbyeMessage()
        defer { farewell = nil }
        handshake = nil
        onChannelSet?(nil)
        handshakeTimer?.invalidate()
        handshakeTimer = nil
        if phase != .idle { endPairing(.cancelled) }
        central.disconnectCurrent(skipForSession: false)
    }

    private func pairingMessage(_ message: PeripheralMessage) {
        // Once this side confirmed there is nothing more to exchange; anything else the iPhone sends is ignored.
        guard phase != .confirmed else { return }
        guard window.isOpen(at: clock()) else {
            // Outside the window an offer is ignored. The peripheral is dropped and, so that a phone that keeps offering
            // cannot make this a reconnect loop, not connected to again until the receiving session ends.
            Self.log.info("pair message ignored outside the pairing window")
            handshake = nil
            handshakeTimer?.invalidate()
            handshakeTimer = nil
            central.disconnectCurrent(skipForSession: true)
            return
        }
        if case .pairOffer = message {
            // One attempt per connection, and every attempt starts with a key nobody has seen.
            guard attempt == nil else { return failAuth() }
            attempt = MacPairing(privateKey: P256.KeyAgreement.PrivateKey())
        }
        guard var current = attempt else { return failAuth() }
        let output = current.receive(message)
        attempt = current
        switch output {
        case .send(let reply):
            central.send(reply)
        case .completed:
            if let sas = current.sas { phase = .confirming(sas: sas) }
        case .failed:
            endPairing(.failed)
        }
    }

    private func discardAttempt(_ result: PairingResult) {
        attempt = nil
        window.close()
        windowTimer?.invalidate()
        windowTimer = nil
        phase = .idle
        lastResult = result
    }

    /// Ends the window and any attempt in it. The pairing connection is dropped (and receiving that the window turned on
    /// turned off); an authenticated keyboard that happened to connect during the window is not the pairing connection and
    /// is left alone, so receiving then stays on.
    private func endPairing(_ result: PairingResult) {
        let keyboardConnected = handshake?.isAuthenticated == true
        discardAttempt(result)
        Self.log.info("pairing ended")
        if keyboardConnected {
            armedByPairing = false
            return
        }
        handshake = nil
        handshakeTimer?.invalidate()
        handshakeTimer = nil
        if armedByPairing {
            armedByPairing = false
            central.stopReceiving()
        } else {
            central.disconnectCurrent(skipForSession: false)
        }
    }
}
