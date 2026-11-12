import CryptoKit
import Foundation
import OSLog
import RemoteKeyboardCore

/// Everything about who may type on this Mac: the per-connection handshake, the pairing window and the paired phones
/// (docs/protocol/v4.md §5 to §7, §10).
///
/// - Every connection starts with a fresh `MacHandshake` and a fresh nonce, and is told apart by how it was found. Through the
///   selected UUID it walks the handshake: nothing but `hello` is written until a stored phone proved its key (which phone it
///   is, is not known beforehand; every stored key is tried). Through the pairing UUID nothing is written; the phone speaks
///   first with its pairing offer. After the handshake every `ack`, `status` and `bye` goes out sealed (`sealControl`), and
///   events are accepted only as sealed payloads that open under this connection's session key.
/// - A plaintext event, a failed proof, a failed open, bytes that are not a message, a message of the wrong route, or a second
///   keyboard session on the same connection ends in `authFailed`, a disconnect, and no reconnection to that peripheral in this
///   receiving session (inside a pairing window the peripheral is not skipped: it may be the phone the user is about to pair).
/// - Three things end a connection without `authFailed`: the keyboard says `notSelected` (it types to another host), the
///   handshake does not finish in 5 seconds, and a message of another protocol version arrives. The first two hold that device
///   off for 10 seconds, the third for 60 (not inside a pairing window); no error is shown, except 「請更新 iPhone App」.
/// - Pairing runs only inside the 120 second window the user opens from the menu. Each attempt uses a new private key.
///   The phone and its pair key are stored only when the user taps 確認 on the Mac; cancel, timeout, mismatch and any failure
///   discard them. Up to eight phones are stored; the window is not opened when eight are.
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
        /// Eight phones are stored already.
        case full
    }

    /// What the panel says when a message of another protocol version arrived (docs/protocol/v4.md §10).
    static let updatePhoneText = "請更新 iPhone App"

    @Published private(set) var phase: PairingPhase = .idle
    /// The stored phones, oldest first. Identities only: no key is held here.
    @Published private(set) var phones: [PhoneIdentity] = []
    @Published private(set) var lastResult: PairingResult?
    /// The name of the phone that is connected and verified; `nil` otherwise.
    @Published private(set) var connectedPhoneName: String?
    /// The name of the phone whose pairing is being confirmed, for the confirmation prompt.
    @Published private(set) var pairingPhoneName: String?
    /// 「請更新 iPhone App」 after a message of another protocol version, until a phone authenticates.
    @Published private(set) var updatePhoneNote: String?

    var isPaired: Bool { !phones.isEmpty }

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
    private var channelSetObservers: [@MainActor (ChannelSet?) -> Void] = []

    /// Another receiver of the channel set besides `onChannelSet` (which the Debug measurement owns): told in the same
    /// moments, after `onChannelSet`, in the order they were added.
    func observeChannelSet(_ observer: @escaping @MainActor (ChannelSet?) -> Void) {
        channelSetObservers.append(observer)
    }

    private func notifyChannelSet(_ channels: ChannelSet?) {
        onChannelSet?(channels)
        for observer in channelSetObservers { observer(channels) }
    }

    private let central: ReceiverBLECentral
    private let store: PairingStoring
    private let clock: () -> Date
    private let makeNonce: @MainActor () -> Data
    private let handshakeTimeout: TimeInterval

    private var handshake: MacHandshake?
    /// The phone whose key the handshake of the authenticated connection matched.
    private var connectedPhoneId: Data?
    /// The goodbye `removePhone` sealed before it dropped the handshake, for whichever disconnect happens first.
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
        central: ReceiverBLECentral, store: PairingStoring, clock: @escaping () -> Date = Date.init,
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

    func refreshPairedState() { phones = store.loadPhones().map(\.identity) }

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
        let route = central.connectionRoute
        var next = MacHandshake(hostId: store.loadHost().id, phones: store.loadPhones(), hostNonce: makeNonce(), route: route)
        switch route {
        case .selected:
            // Found through the selected UUID: `hello` if anybody is paired, a failure if nobody is (§6.2).
            switch next.begin() {
            case .send(let hello):
                central.send(hello)
                handshake = next
                startHandshakeTimer()
            case .authFailed:
                handshake = next
                failAuth()
            case .none, .authenticated, .pairOffer, .pairReveal, .event, .malformedPayload, .notSelected:
                handshake = next
                startHandshakeTimer()
            }
        case .pairing:
            // Found through the pairing UUID: nothing is written, the phone speaks first. Without a window there is nobody to
            // pair with (it closed between the scan and the connection).
            guard window.isOpen(at: clock()) else {
                handshake = nil
                central.disconnectCurrent(skipForSession: false)
                return
            }
            handshake = next
            startHandshakeTimer()
        }
    }

    private func linkLost() {
        handshakeTimer?.invalidate()
        handshakeTimer = nil
        handshake = nil
        clearConnectedPhone()
        pin = SessionPin()
        notifyChannelSet(nil)
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
        clearConnectedPhone()
        notifyChannelSet(nil)
        central.send(.authFailed)
        Self.log.info("authentication failed, peripheral dropped")
        // A pairing attempt dies with its connection, and the window with it. A failure on any other connection leaves
        // an open window alone, and inside it the peripheral is not skipped: it may be the iPhone the user is about to pair
        // (a keyboard that was still on screen when the window opened).
        if attempt != nil { return endPairing(.failed) }
        central.disconnectCurrent(skipForSession: phase == .idle)
    }

    private func startHandshakeTimer() {
        handshakeTimer?.invalidate()
        handshakeTimer = CommonModeTimer.make(handshakeTimeout, repeats: false) { [weak self] in self?.handshakeTimerFired() }
    }

    /// A peripheral that has not authenticated in time is dropped, with no word to it and without `authFailed`, and held off for
    /// 10 seconds (docs/protocol/v4.md §6.2, §6.4). While a pairing window waits, that holds for a peripheral that has made no
    /// offer too (the App sends its offer right on subscribe, so a silent one is not about to pair, and it must not hold the
    /// only connection for the whole window). Once an attempt is on the connection, or this side is confirming or has
    /// confirmed, only the window's own deadline bounds it.
    func handshakeTimerFired() {
        guard let handshake, !handshake.isAuthenticated, attempt == nil else { return }
        guard phase == .idle || phase == .waiting else { return }
        Self.log.info("handshake timed out, peripheral dropped")
        dropConnectionState()
        central.handshakeTimedOut()
    }

    /// The handshake, its timer and everything the connection handed out are gone; the connection itself is the caller's to end.
    private func dropConnectionState() {
        handshakeTimer?.invalidate()
        handshakeTimer = nil
        handshake = nil
        clearConnectedPhone()
        notifyChannelSet(nil)
    }

    private func clearConnectedPhone() {
        connectedPhoneId = nil
        connectedPhoneName = nil
    }

    /// A message of another protocol version: say so on the panel, drop the connection and, outside a pairing window, hold the
    /// device off for 60 seconds. Inside the window it may be the phone the user is about to pair.
    private func unsupportedVersion() {
        updatePhoneNote = Self.updatePhoneText
        Self.log.info("protocol version not supported, peripheral dropped")
        dropConnectionState()
        if attempt != nil { return endPairing(.failed) }
        central.peripheralUnsupportedVersion(hold: phase == .idle)
    }

    /// The keyboard types to another host. Not an error: nothing is written, nothing is shown, the device is held off for
    /// 10 seconds and is not on the skip list.
    private func notSelected() {
        Self.log.info("keyboard types to another host, peripheral dropped")
        dropConnectionState()
        central.peripheralNotSelected()
    }

    // MARK: Messages from the keyboard

    private func receive(_ data: Data) {
        guard var current = handshake else { return }
        let message: PeripheralMessage
        do {
            message = try PeripheralCodec.decode(data)
        } catch EventCodecError.unsupportedVersion {
            return unsupportedVersion()
        } catch {
            return failAuth()
        }
        let output = current.receive(message)
        handshake = current
        switch output {
        case .none, .send:
            break
        case .authenticated(let reply, let phoneId):
            handshakeTimer?.invalidate()
            handshakeTimer = nil
            central.send(reply)
            connectedPhoneId = phoneId
            connectedPhoneName = current.authenticatedPhone?.name
            updatePhoneNote = nil
            if let channels = current.takeChannelSet() {
                handshake = current
                notifyChannelSet(channels)
            }
            onAuthenticated?()
        case .pairOffer, .pairReveal:
            pairingMessage(message)
        case .event(let event):
            guard pin.accept(event.sessionId) else { return failAuth() }
            onEvent?(event)
        case .malformedPayload:
            onMalformed?()
        case .notSelected:
            notSelected()
        case .authFailed:
            failAuth()
        }
    }

    // MARK: Pairing

    /// Menu 「配對新 iPhone」. Opens the 120 second window, turns receiving on if it was off, and starts a fresh scan that
    /// includes the pairing UUID. Refused, with 「已配對 8 支手機」, when eight phones are stored.
    func openPairingWindow() {
        guard phase == .idle else { return }
        lastResult = nil
        guard store.loadPhones().count < PairedList<PairedPhone>.capacity else {
            lastResult = .full
            return
        }
        window.open(now: clock())
        phase = .waiting
        central.setPairingScan(true)
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

    /// 「確認」 on the Mac. Stores the phone and its pair key; only reachable from the SAS prompt, and only inside the window.
    func confirmPairing() {
        guard case .confirming = phase, let key = attempt?.pairKey, let identity = attempt?.phone else { return }
        guard window.isOpen(at: clock()) else { return endPairing(.timedOut) }
        do {
            try store.save(PairedPhone(identity: identity, pairKey: key))
        } catch {
            // Show what the store really holds.
            refreshPairedState()
            return endPairing((error as? PairingStoreError) == .full ? .full : .storeFailed)
        }
        refreshPairedState()
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

    /// 「刪除」 on a phone of the list: forgets its pair key. A connection that could still prove that key ends: the phone itself,
    /// connected, is told goodbye first (a sealed `bye`, docs/protocol/v4.md §7.4); a handshake that is still running is dropped.
    /// A different phone that is typing is left alone.
    func removePhone(id: Data) {
        let wasTyping = connectedPhoneId == id && handshake?.isAuthenticated == true
        let handshaking = central.connectionRoute == .selected && handshake != nil && handshake?.isAuthenticated == false
        store.delete(phoneId: id)
        refreshPairedState()
        guard wasTyping || handshaking else { return }
        // The goodbye is sealed while the handshake still exists; whichever disconnect comes first writes it.
        farewell = goodbyeMessage()
        defer { farewell = nil }
        dropConnectionState()
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
            attempt = MacPairing(privateKey: P256.KeyAgreement.PrivateKey(), host: store.loadHost())
        }
        guard var current = attempt else { return failAuth() }
        let output = current.receive(message)
        attempt = current
        switch output {
        case .send(let reply):
            central.send(reply)
        case .completed:
            if let sas = current.sas {
                pairingPhoneName = current.phone?.name
                phase = .confirming(sas: sas)
            }
        case .failed:
            endPairing(.failed)
        }
    }

    private func discardAttempt(_ result: PairingResult) {
        attempt = nil
        pairingPhoneName = nil
        window.close()
        // The pairing UUID is not scanned any more, and a scan that is running stops looking for it at once.
        central.setPairingScan(false)
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
