import CoreBluetooth
import CryptoKit
import Foundation
import Network
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
    /// How the current Mac connection's handshake ended. For the setup checklist only.
    private var onHandshake: ((HandshakeOutcome) -> Void)?

    enum HandshakeOutcome { case authenticated, failed }

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

    /// The hosts this iPhone has paired and the one the keyboard types to, as of the last appearance, connection or switch.
    /// Empty when nothing is paired (or the Extension has no Full Access and cannot read the App Group).
    private var hostSelection = HostSelection()
    /// The current host's pair key as of the same moment; `nil` when there is no current host, or its key cannot be read
    /// (the Extension has no Full Access).
    private var pairKey: SymmetricKey?
    /// One per Mac connection, with its own nonce. Events leave only once it `canSendEvents`, and only sealed.
    private var handshake: PhoneHandshake? {
        didSet {
            if handshake == nil {
                handshakeHostId = nil
                connectionEnded()
            }
        }
    }
    /// The host the handshake above was built for. The host list is read again at each appearance and can differ by then.
    private var handshakeHostId: Data?

    /// The counter channels of the authenticated connection, kept until it ends. One set per connection: the touchpad and
    /// (Debug builds) the measurement both use its sealers, so no key ever sees a counter that starts at 1 twice.
    private var channels: ChannelSet?

    /// Which of a long text's frames and a touchpad packet (or, in Debug builds, a measurement probe) goes next
    /// (spec §8.2 rule 4).
    private var interleave = TransmitInterleave()
    /// The radio refused a notification and has not said it is ready again. Only the touchpad drain looks at it.
    private var radioBlocked = false

    // Touchpad (pointer) channel. Memory only, and all of it belongs to one connection.
    private(set) var pointerState = PointerChannelPhase.closed {
        didSet { if pointerState != oldValue { onPointerChange?() } }
    }
    /// The touchpad page is waiting to hear about the channel (set while the page is shown).
    var onPointerChange: (() -> Void)?
    /// The packets of the open channel; nil while it is not open.
    private(set) var pointerSender: PointerSender?
    /// The trackpad's send rate (`TrackpadSendRate`, 0 is 自動), set by the coordinator; a new sender starts with it.
    var pointerSendRate = TrackpadSendRate.defaultValue {
        didSet { pointerSender?.rate = pointerSendRate }
    }
    private var pointerOpenEventId: UUID?
    /// Ids of `pointerOpen` and `pointerClose` events: their acks are not typed keys and say nothing in the status line.
    private var pointerEventIds: Set<UUID> = []
    /// The grant the open (or refused) attempt used.
    private var pointerGrant: UInt32?
    /// How many `pointerOpen` were sent for the current page visit; the second one is the last.
    private var pointerAttempts = 0
    private var pointerOpenTimer: Timer?

    // Wi-Fi assist (spec D30). The listener, the probe bookkeeping and which way the packets go belong to one touchpad channel.
    /// The UDP listener and send side; exists from the moment a `pointerOpen` is prepared until the channel ends.
    private var wifiLink: WifiPointerLink?
    /// Waiting for the listener's port before `pointerOpen` can leave (at most `WifiPointerLink.readyTimeout`).
    private var wifiOpenPending = false
    private var wifiMonitor = PointerPathMonitor()
    /// Where cursor packets go right now. Re-evaluated at every drain, so a lapse of the probes shows within the live window.
    private(set) var pointerPath = PointerPath.bluetooth {
        didSet { if pointerPath != oldValue { onPointerChange?() } }
    }
    /// The connection interval asked for, from typing and the pointer. `appliedLatency` is what the current central was last
    /// asked for; `latencyTimer` is the single one-shot that fires when the link turns idle.
    private var latencyPolicy = LinkLatencyPolicy()
    private var appliedLatency: LinkLatencyPolicy.Level?
    private var latencyTimer: Timer?
    private static let pointerOpenTimeout: TimeInterval = 1.5

    // Reconnect timing of the current appearance, and the one probe sent for it.
    private var tracker = ReconnectTracker()
    private var pingEventId: UUID?

    /// The liveness probe of the current appearance: sent when a keyboard appears on a link that looks connected. A `pong`
    /// for it cancels the 2 second deadline; none means the link is dead and the service is published again.
    private var probe = LinkProbe()
    private var probeTimer: Timer?

    private static let serviceID = CBUUID(string: GATTServiceSpec.Link.serviceUUID)
    private static let eventID = CBUUID(string: GATTServiceSpec.Link.eventUUID)
    private static let controlID = CBUUID(string: GATTServiceSpec.Link.controlUUID)

    var linkState: KeyboardLinkState { machine.state }

    #if DEBUG
    // TP1 measurement (Debug builds only). The channel set of the authenticated connection is kept until it ends.
    /// 3,000 characters in one `TEXT` (6,000 UTF-8 bytes): the T07 check and the load of M5, M6-L and M7.
    static let debugLongText = MeasureLongText.text

    enum LatencySetting: Equatable {
        case unset, low, medium
        var title: String {
            switch self {
            case .unset: "延遲 預設"
            case .low: "延遲 低"
            case .medium: "延遲 中"
            }
        }
    }

    var measureChannels: ChannelSet? { channels }
    private(set) lazy var measurement = MeasurementRunner(peripheral: self)
    private(set) var latencySetting = LatencySetting.unset
    /// How long an `updateValue` refusal lasted, in microseconds, reported when the radio is ready again.
    private var blockedSince: UInt64?

    /// Authenticated, subscribed, and the Mac says its measurement mode is on.
    var isMeasureReady: Bool {
        machine.state == .connected && subscribedCentral != nil && handshake?.canSendEvents == true
            && measureChannels != nil && latestStatus?.measure == true
    }

    var hasQueuedFrames: Bool { queue.pendingCount > 0 }

    /// Hands one sealed measurement packet to `updateValue`. `false` when the radio refused it or no central is subscribed.
    func sendChannelPacket(_ packet: Data) -> Bool {
        guard let manager, let eventCharacteristic, let central = subscribedCentral else { return false }
        let accepted = manager.updateValue(packet, for: eventCharacteristic, onSubscribedCentrals: [central])
        if !accepted { noteBlocked() }
        return accepted
    }

    /// One `TEXT` of 3,000 characters through the normal send path.
    @discardableResult
    func sendDebugLongText() -> Bool { send(.text(Self.debugLongText)) != nil }

    /// 預設 → 低 → 中 → 預設. "預設" makes no call; it only takes effect on the next connection, since CoreBluetooth has no way
    /// back to the system's default once a latency was requested.
    func cycleLatency() {
        switch latencySetting {
        case .unset: latencySetting = .low
        case .low: latencySetting = .medium
        case .medium: latencySetting = .unset
        }
        applyLatency()
        if latencySetting == .unset { reconcileLatency() }
    }

    /// Asks the subscribed central for the latency a measurement run wants; nothing for `.none`. Returns whether a request
    /// was made. A request stays in force until the connection ends, so a later run that asks for nothing is told what is
    /// still active (`latencyCarryover`).
    @discardableResult
    func requestMeasureLatency(_ preference: MeasureLatencyPreference) -> Bool {
        switch preference {
        case .none: return false
        case .low: latencySetting = .low
        case .medium: latencySetting = .medium
        }
        guard manager != nil, subscribedCentral != nil else { return false }
        applyLatency()
        return true
    }

    /// The name of a latency request that is still in force on this connection, if any.
    var latencyCarryover: String? {
        switch latencySetting {
        case .unset: appliedLatency.map { "\($0)" }
        case .low: "low"
        case .medium: "medium"
        }
    }

    private func applyLatency() {
        guard let manager, let central = subscribedCentral else { return }
        switch latencySetting {
        case .unset: break
        case .low: manager.setDesiredConnectionLatency(.low, for: central)
        case .medium: manager.setDesiredConnectionLatency(.medium, for: central)
        }
    }

    private func noteBlocked() {
        if blockedSince == nil { blockedSince = MeasureClock.nowMicros() }
    }

    private func measureConnectionEnded() {
        blockedSince = nil
        // A latency request belongs to the connection it was made on.
        latencySetting = .unset
        measurement.connectionEnded()
    }
    #endif

    /// Everything that belongs to one Mac connection goes with it.
    private func connectionEnded() {
        channels = nil
        pointerConnectionEnded()
        resetLatency()
        #if DEBUG
        measureConnectionEnded()
        #endif
    }

    /// Shown-to-connected time of this appearance, once the link has connected.
    var reconnectLatencyMs: Int64? { tracker.latencyMs }

    // MARK: Touchpad channel

    /// Connected, authenticated, and the Mac has announced a grant: the touchpad page can ask to open.
    var canOpenPointer: Bool {
        machine.state == .connected && subscribedCentral != nil && handshake?.canSendEvents == true && channels != nil
            && latestStatus?.pointerGrant != nil
    }

    /// What the page shows for the channel right now.
    var pointerAvailability: TrackpadAvailability {
        TrackpadPage.availability(linkConnected: machine.state == .connected, status: latestStatus, channel: pointerState)
    }

    /// Whether `grant` is one this phone may ask to open with now. A refused attempt is repeated only when the Mac announces
    /// another grant.
    private func mayOpenPointer(grant: UInt32) -> Bool {
        guard canOpenPointer, latestStatus?.pointerGrant == grant else { return false }
        switch pointerState {
        case .closed: return true
        case .denied: return grant != pointerGrant
        case .opening, .open, .timedOut: return false
        }
    }

    /// Asks the Mac to accept pointer packets, with the grant its last status carried. `0x03` packets are sent only after the
    /// Mac answers `posted`. With 「經 Wi-Fi 傳送游標」 on, the request carries the phone's listener port and addresses, so the
    /// Mac can probe (§8.6); it waits for the listener at most `WifiPointerLink.readyTimeout`.
    func openPointer() {
        guard let grant = latestStatus?.pointerGrant, !wifiOpenPending, mayOpenPointer(grant: grant) else { return }
        // The fast interval is asked for before the open leaves the phone.
        setPointerLatency(open: true)
        let group = UserDefaults(suiteName: AppGroup.identifier)
        guard WifiPointerSetting.isEnabled(stored: group?.object(forKey: AppGroup.Key.wifiPointer)) else {
            // Switched off since an earlier attempt: a listener left over from it is not wanted. Closing it can publish a path
            // change, which asks the page to refresh, which calls `openPointer()` again before this one is done; that nested
            // call sends the open (the setting is off there too). If it did, this one must not send a second.
            let attempts = pointerAttempts
            stopWifi()
            guard pointerAttempts == attempts else { return }
            sendPointerOpen(grant: grant, wifi: nil)
            return
        }
        wifiOpenPending = true
        let link = wifiLink ?? makeWifiLink()
        link.start { [weak self] port in self?.wifiListenerAnswered(port: port, grant: grant) }
    }

    private func wifiListenerAnswered(port: UInt16?, grant: UInt32) {
        wifiOpenPending = false
        KeyboardLifecycleLog.note(.wifiListener(portPresent: port != nil))
        // The listener took a moment: the link, the status or the page may have changed meanwhile.
        guard mayOpenPointer(grant: grant) else {
            // A newer grant arrived while the listener started: its refresh found the open pending and did nothing.
            if let newer = latestStatus?.pointerGrant, mayOpenPointer(grant: newer) {
                openPointer()
            } else {
                stopWifi()
                setPointerLatency(open: false)
            }
            return
        }
        let offer = port.flatMap { WifiOffer(addrs: LocalAddresses.current(), port: $0) }
        // No port or no usable address: the Mac is not asked to probe, and a listener nobody uses is not kept.
        if offer == nil { stopWifi() }
        sendPointerOpen(grant: grant, wifi: offer)
    }

    private func sendPointerOpen(grant: UInt32, wifi: WifiOffer?) {
        guard let id = send(.pointerOpen(grant: grant, wifi: wifi)) else {
            setPointerLatency(open: false)
            stopWifi()
            return
        }
        pointerAttempts += 1
        schedulePointerOpenTimeout()
        pointerOpenEventId = id
        pointerEventIds.insert(id)
        pointerGrant = grant
        pointerState = .opening
    }

    /// The page was left: whatever is held is released, the Mac is told, and the latency goes back to medium.
    func closePointer() {
        let wasActive = pointerState == .opening || pointerState == .open
        if let sender = pointerSender {
            sender.releaseAll(atMicros: PointerClock.nowMicros())
            drain()
        }
        pointerSender = nil
        pointerOpenEventId = nil
        if wasActive, let id = send(.pointerClose) { pointerEventIds.insert(id) }
        pointerGrant = nil
        pointerAttempts = 0
        cancelPointerOpenTimeout()
        interleave.mode = .keyboard
        endPointerChannel(as: .closed)
        setPointerLatency(open: false)
    }

    private func schedulePointerOpenTimeout() {
        pointerOpenTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pointerOpenTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerOpenTimedOut() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerOpenTimer = timer
    }

    private func cancelPointerOpenTimeout() {
        pointerOpenTimer?.invalidate()
        pointerOpenTimer = nil
    }

    /// No answer to `pointerOpen`: a fresh one is sent once (a new event); after the second silence the page says so.
    private func pointerOpenTimedOut() {
        pointerOpenTimer = nil
        guard pointerState == .opening else { return }
        pointerOpenEventId = nil
        if pointerAttempts < 2 {
            pointerState = .closed
            openPointer()
        } else {
            endPointerChannel(as: .timedOut)
            setPointerLatency(open: false)
        }
    }

    /// Hands what the sender has to the radio.
    func pumpPointer() { drain() }

    private func setPointerLatency(open: Bool) {
        latencyPolicy.setPointerOpen(open)
        if open { latencyPolicy.noteActivity(atMs: MonotonicClock.nowMs()) }
        reconcileLatency()
    }

    /// Asks the subscribed central for the interval the policy wants, only when it differs from the last ask, and arms the
    /// one-shot that fires when the link turns idle. A measurement run that requested a latency keeps control.
    private func reconcileLatency() {
        cancelLatencyTimer()
        guard let manager, let central = subscribedCentral else { return }
        #if DEBUG
        if latencySetting != .unset {
            appliedLatency = nil
            return
        }
        #endif
        let now = MonotonicClock.nowMs()
        let level = latencyPolicy.desired(atMs: now)
        if level != appliedLatency {
            switch level {
            case .low: manager.setDesiredConnectionLatency(.low, for: central)
            case .medium: manager.setDesiredConnectionLatency(.medium, for: central)
            case .high: manager.setDesiredConnectionLatency(.high, for: central)
            }
            appliedLatency = level
        }
        guard let changeAt = latencyPolicy.nextChangeAtMs(atMs: now) else { return }
        let timer = Timer(timeInterval: Double(max(changeAt - now, 1)) / 1000, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.latencyTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        latencyTimer = timer
    }

    private func latencyTimerFired() {
        latencyTimer = nil
        reconcileLatency()
    }

    private func cancelLatencyTimer() {
        latencyTimer?.invalidate()
        latencyTimer = nil
    }

    /// The link is gone or replaced: the next central is asked afresh, and nothing waits to fire.
    private func resetLatency() {
        cancelLatencyTimer()
        latencyPolicy = LinkLatencyPolicy()
        appliedLatency = nil
    }

    private func pointerConnectionEnded() {
        pointerSender = nil
        pointerOpenEventId = nil
        pointerEventIds.removeAll()
        pointerGrant = nil
        pointerAttempts = 0
        cancelPointerOpenTimeout()
        interleave.mode = .keyboard
        radioBlocked = false
        endPointerChannel(as: .closed)
    }

    /// The Mac's answer to the latest `pointerOpen`.
    private func pointerOpenAnswered(_ result: AckCode) {
        guard pointerState == .opening else { return }
        cancelPointerOpenTimeout()
        if result == .posted {
            pointerSender = PointerSender(rate: pointerSendRate)
            pointerState = .open
        } else {
            endPointerChannel(as: .denied)
            setPointerLatency(open: false)
        }
    }

    /// A status that no longer carries the grant the channel was opened with means the Mac closed it (the switch went
    /// off) or invalidated it: the sender stops and the page asks again with the new grant, if there is one.
    private func reconcilePointer(with status: ReceiverStatus) {
        guard pointerState == .opening || pointerState == .open, status.pointerGrant != pointerGrant else { return }
        pointerSender = nil
        pointerOpenEventId = nil
        pointerAttempts = 0
        cancelPointerOpenTimeout()
        interleave.mode = .keyboard
        setPointerLatency(open: false)
        endPointerChannel(as: status.pointerGrant == nil ? .denied : .closed)
    }

    /// The channel ended or was refused. The Wi-Fi listener is closed **before** the state changes: setting `pointerState` calls
    /// `onPointerChange` at once, and the page may answer by calling `openPointer()`. Done the other way round, that open would
    /// find the old listener still running, offer its port, and the listener would be closed a moment later, so the Receiver
    /// would probe a dead port. With the listener gone first, the open starts a new one.
    private func endPointerChannel(as state: PointerChannelPhase) {
        stopWifi()
        pointerState = state
    }

    // MARK: Wi-Fi assist

    private func makeWifiLink() -> WifiPointerLink {
        let link = WifiPointerLink()
        link.onDatagram = { [weak self] data, endpoint in self?.wifiDatagramArrived(data, from: endpoint) }
        link.onSendFailure = { [weak self] in self?.wifiSendFailed() }
        wifiLink = link
        return link
    }

    /// A datagram reached the listener. It counts only when it opens as a probe with this connection's keys (a forged or replayed
    /// one changes nothing, `PointerPathMonitor.handleProbe`); the flow it came from then becomes the send target.
    private func wifiDatagramArrived(_ data: Data, from endpoint: NWEndpoint) {
        guard pointerState == .opening || pointerState == .open, let opener = channels?.opener(.wifiProbe) else { return }
        let now = PointerClock.nowMicros()
        guard wifiMonitor.handleProbe(data, opener: opener, atMicros: now) else { return }
        wifiLink?.adopt(endpoint)
        refreshPointerPath(atMicros: now, downReason: .probeTimeout)
    }

    /// The system refused a send, or the target's flow broke (for example `localNetworkDenied`): Bluetooth at once, and the
    /// monitor ignores probes for a while so the path does not flap.
    private func wifiSendFailed() {
        let now = PointerClock.nowMicros()
        wifiLink?.dropTarget()
        wifiMonitor.sendFailed(atMicros: now)
        refreshPointerPath(atMicros: now, downReason: .sendFailed)
    }

    /// Brings `pointerPath` in line with the monitor and logs the change. A change to Bluetooth seen here is the probes running out.
    private func refreshPointerPath(atMicros now: UInt64, downReason: WifiPathDownReason) {
        let path = wifiMonitor.path(atMicros: now, targetReady: wifiLink?.isTargetReady ?? false)
        guard path != pointerPath else { return }
        pointerPath = path
        KeyboardLifecycleLog.note(path == .wifi ? .wifiPathUp : .wifiPathDown(reason: downReason))
    }

    /// The listener, the target and the monitor go with the channel; the path is Bluetooth again.
    private func stopWifi() {
        wifiOpenPending = false
        wifiLink?.stop()
        wifiLink = nil
        wifiMonitor.reset()
        if pointerPath == .wifi {
            pointerPath = .bluetooth
            KeyboardLifecycleLog.note(.wifiPathDown(reason: .closed))
        }
    }

    /// Nobody owns the peripheral; a controller that is still on screen may reclaim it.
    var isVacant: Bool { ownership.isVacant }

    /// Whether this iPhone holds the pair key of its current host.
    var isPaired: Bool { pairKey != nil }

    /// The host the keyboard types to, and how many hosts are paired. The status cell shows the name from two hosts on.
    var currentHost: HostIdentity? { hostSelection.selected }
    var hostCount: Int { hostSelection.hosts.count }

    /// The current host with its key: what is advertised and what the handshake answers for. `nil` while nothing is paired.
    private var selectedPair: (host: HostIdentity, pairKey: SymmetricKey)? {
        guard let host = hostSelection.selected, let pairKey else { return nil }
        return (host, pairKey)
    }

    /// Remote keys are accepted only with a connected link, a subscribed central that proved the pair key, and a Receiver
    /// that says it is ready.
    var isRemoteReady: Bool {
        machine.state == .connected && subscribedCentral != nil && handshake?.canSendEvents == true
            && latestStatus?.ready == true
    }

    /// The link is up and the Mac proved the pair key, whether or not the Mac can take input right now.
    var isLinkAuthenticated: Bool {
        machine.state == .connected && subscribedCentral != nil && handshake?.canSendEvents == true
    }

    private override init() { super.init() }

    /// A controller that no longer owns the peripheral never sends.
    func isRemoteReady(for owner: UUID) -> Bool { ownership.isOwner(owner) && isRemoteReady }

    /// Whether `owner` is the controller that currently holds the peripheral.
    func isOwner(_ owner: UUID) -> Bool { ownership.isOwner(owner) }

    /// `owner` takes the callbacks and feeds `.appeared`. A claim by a new owner starts a new session (id, seq,
    /// queue) but keeps a live subscription, so a replacement controller does not drop an established link.
    func appear(
        owner: UUID, hasFullAccess: Bool,
        onStateChange: @escaping (KeyboardLinkState) -> Void,
        onControl: @escaping (ControlMessage) -> Void,
        onNote: @escaping (String) -> Void,
        onHandshake: ((HandshakeOutcome) -> Void)? = nil
    ) {
        let hadOwner = ownership.owner != nil
        // The clock starts when the owning controller's appearance starts. A replacement controller or a repeated
        // appear inside a running appearance keeps the original start.
        var appearanceStarts = tracker.beginIfIdle(atMs: MonotonicClock.nowMs())
        if ownership.claim(owner) {
            KeyboardLifecycleLog.note(.ownerChanged(owner: owner, hadPrevious: hadOwner))
            if hadOwner { startSession() }
            appearanceStarts = true
        }
        self.onStateChange = onStateChange
        self.onControl = onControl
        self.onNote = onNote
        self.onHandshake = onHandshake
        // Without Full Access no CBPeripheralManager is created at all.
        if hasFullAccess && manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: nil)
            KeyboardLifecycleLog.note(.managerCreated)
        }
        // The host list and the current host's key are read at each appearance (and again per connection) so a pairing made
        // in the host App since the last time is picked up. Without Full Access the read fails and the keyboard is simply
        // unpaired.
        loadHosts()
        // The App deleted or selected another host while a connection to the old one was still up.
        if LinkRecovery.shouldResetForHostChange(
            connectionHostId: handshakeHostId, currentHostId: hostSelection.selected?.id, hasHandshake: handshake != nil) {
            resetLink()
        }
        feed(.appeared(hasFullAccess: hasFullAccess))
        // The link machine has torn the service down by now; a manager an earlier controller created must not outlive it.
        if !hasFullAccess { releaseManager() }
        // A replacement controller can appear on a link the Mac already left without iOS saying so (the system keeps its
        // own link up after the Mac cancels). Ask the Mac; no answer in 2 seconds publishes the service again.
        if appearanceStarts {
            // A connected link whose handshake already failed can never recover by itself; a live one is probed instead.
            if LinkRecovery.shouldResetOnAppear(
                linkConnected: machine.state == .connected, handshake: handshake?.progress, hasPairKey: pairKey != nil
            ) {
                resetLink()
            } else {
                probeLinkIfConnected()
            }
        }
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
        onHandshake = nil
    }

    /// A controller is going away. Same as a disappear when it is still the owner, otherwise nothing.
    func release(owner: UUID) {
        guard ownership.isOwner(owner) else { return }
        KeyboardLifecycleLog.note(.ownerReleasedByDeinit(owner: owner))
        disappear(owner: owner)
    }

    private func loadHosts() {
        hostSelection = PairingStore.loadHosts()
        pairKey = hostSelection.selected.flatMap { PairingStore.loadPairKey(hostId: $0.id) }
        if pairKey == nil { KeyboardLifecycleLog.note(.pairKeyMissing) }
    }

    /// The status cell was tapped: the keyboard types to the next paired host. The new current host is saved, the service is
    /// published again so it advertises the new host's selected UUID, and the connection to the old host is dropped with
    /// everything that belonged to it (docs/protocol/v4.md §1.2). Returns the new host, or `nil` (nothing changed) with fewer
    /// than two hosts.
    @discardableResult
    func cycleHost() -> HostIdentity? {
        // The App may have added or removed a host since the last read; the cycle starts from what is stored now.
        var selection = PairingStore.loadHosts()
        guard let next = selection.cycle() else { return nil }
        PairingStore.saveHosts(selection)
        hostSelection = selection
        pairKey = PairingStore.loadPairKey(hostId: next.id)
        if pairKey == nil { KeyboardLifecycleLog.note(.pairKeyMissing) }
        resetLink()
        return next
    }

    /// Tears down the peripheral manager and everything tied to it (used when Full Access is off).
    private func releaseManager() {
        guard let manager else { return }
        manager.stopAdvertising()
        manager.removeAllServices()
        manager.delegate = nil
        self.manager = nil
        eventCharacteristic = nil
        cancelProbe()
        subscribedCentral = nil
        resetLatency()
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
        resetLatency()
        binding.clear()
        latestStatus = nil
        tracker.reset()
        pingEventId = nil
        cancelProbe()
        clearPendingService()
    }

    private func clearPendingService() {
        pendingService.clear()
        pendingServiceObject = nil
    }

    // MARK: Sending

    /// Typed keys sent in this appearance and not yet answered by the Mac (probes excluded). The debug burst reads it
    /// to keep a window of unanswered keys.
    var pendingKeyCount: Int { sender.pendingCount }

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
        // Typing is activity; the slower interval is lifted before the first frame is handed to the radio.
        if kind.carriesFocusEpoch {
            latencyPolicy.noteActivity(atMs: MonotonicClock.nowMs())
            reconcileLatency()
        }
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

    // MARK: Liveness probe and link reset

    /// Sends one probe when this is a new appearance on a connected, authenticated link. A probe still pending keeps its own
    /// deadline. The probe is not a typed key and not a reconnect sample.
    private func probeLinkIfConnected() {
        guard machine.state == .connected, subscribedCentral != nil, handshake?.canSendEvents == true, !probe.isPending,
              let eventId = send(.probe) else { return }
        probe.start(eventId: eventId, nowMs: MonotonicClock.nowMs())
        KeyboardLifecycleLog.note(.probeSent)
        scheduleProbeTimer(after: Double(LinkProbe.timeoutMs) / 1000)
    }

    private func scheduleProbeTimer(after seconds: TimeInterval) {
        probeTimer?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.probeTimerFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        probeTimer = timer
    }

    private func probeTimerFired() {
        probeTimer = nil
        guard probe.isPending else { return }
        // The timer cannot fire early, but the deadline is the probe's, not the timer's.
        guard probe.isExpired(nowMs: MonotonicClock.nowMs()) else { return scheduleProbeTimer(after: 0.05) }
        KeyboardLifecycleLog.note(.probeExpired)
        resetLink()
    }

    private func cancelProbe() {
        probe.cancel()
        probeTimer?.invalidate()
        probeTimer = nil
    }

    /// The connection is over although iOS has not said so (the Mac said goodbye, or a probe went unanswered). Publishes
    /// the service again from scratch: advertising alone would leave the old central subscribed as far as iOS knows. The
    /// reset drops the connection state (binding, handshake, status) with the service; `messageId` is never reset.
    private func resetLink() {
        cancelProbe()
        pingEventId = nil
        KeyboardLifecycleLog.note(.linkReset)
        feed(.linkReset)
    }

    /// Hands queued frames to CoreBluetooth in order. A `false` from `updateValue` means the transmit queue is full;
    /// the rest waits for `peripheralManagerIsReady(toUpdateSubscribers:)`.
    private func drain() {
        guard let manager, let eventCharacteristic, let central = subscribedCentral else { return }
        if pointerState == .open, pointerSender != nil {
            drainWithPointer(manager: manager, characteristic: eventCharacteristic, central: central)
            return
        }
        #if DEBUG
        drainTracked(manager: manager, characteristic: eventCharacteristic, central: central)
        #else
        queue.drain { frame in
            manager.updateValue(frame, for: eventCharacteristic, onSubscribedCentrals: [central])
        }
        #endif
    }

    /// The drain while the touchpad is open: one ordered exit for the frames of the typing queue and the sender's packets.
    ///
    /// When the Wi-Fi path is alive (`pointerPath`, §8.6) a packet leaves over UDP, sealed with the same sealer: UDP does not use
    /// the Bluetooth radio, so neither a full radio nor a waiting frame holds it up, and it does not touch `radioBlocked`. A
    /// send that fails marks the path down and the same packet goes the radio's way below, sealed again with a new counter.
    ///
    /// Over Bluetooth the packets come first (four packets, then one frame, when both wait). A refusal by the radio stops
    /// everything on the radio until it is ready again; the refused packet stays in the sender and is sealed again, with a new
    /// counter, when its turn comes.
    private func drainWithPointer(manager: CBPeripheralManager, characteristic: CBMutableCharacteristic, central: CBCentral) {
        guard let sender = pointerSender, let sealer = channels?.sealer(.pointer) else { return }
        interleave.mode = .trackpad
        while true {
            let now = PointerClock.nowMicros()
            refreshPointerPath(atMicros: now, downReason: .probeTimeout)
            // A packet the radio refused earlier waits for the radio; over Wi-Fi it can go now.
            if pointerPath == .wifi, sender.isBlocked { sender.radioReady() }
            let payload = sender.peek(nowMicros: now)
            var route = PointerRoute.choose(path: pointerPath, radioBlocked: radioBlocked)
            if route == .udp, let payload {
                guard let packet = try? sealer.seal(payload.encode()) else {
                    pointerCountersUsedUp()
                    return
                }
                if wifiLink?.send(packet) == true {
                    sender.handedOff(nowMicros: now)
                    continue
                }
                // Not sent because there is no target flow yet, or it is not ready yet. That is not a failure (a real one comes
                // back through `onSendFailure`): this one packet goes by Bluetooth, sealed again, and the path stays as it is.
                route = PointerRoute.choose(path: .bluetooth, radioBlocked: radioBlocked)
            }
            // Frames only ever use the radio.
            guard !radioBlocked else { return }
            let blePayload = route == .bluetooth ? payload : nil
            let hasFrame = queue.pendingCount > 0
            guard let source = interleave.choose(hasFrame: hasFrame, hasPacket: blePayload != nil) else { return }
            switch source {
            case .frame:
                var handedOne = false
                var refused = false
                queue.drain { frame in
                    if handedOne { return false }
                    guard manager.updateValue(frame, for: characteristic, onSubscribedCentrals: [central]) else {
                        refused = true
                        return false
                    }
                    handedOne = true
                    return true
                }
                if refused {
                    radioBlocked = true
                    #if DEBUG
                    noteBlocked()
                    #endif
                    return
                }
                interleave.handed(.frame, otherWaiting: blePayload != nil)
            case .packet:
                guard let blePayload, let packet = try? sealer.seal(blePayload.encode()) else {
                    pointerCountersUsedUp()
                    return
                }
                guard manager.updateValue(packet, for: characteristic, onSubscribedCentrals: [central]) else {
                    sender.refused()
                    radioBlocked = true
                    #if DEBUG
                    noteBlocked()
                    #endif
                    return
                }
                sender.handedOff(nowMicros: now)
                interleave.handed(.packet, otherWaiting: hasFrame)
            }
        }
    }

    /// The counter is used up: nothing more can be sealed on this connection.
    private func pointerCountersUsedUp() {
        pointerSender = nil
        endPointerChannel(as: .closed)
        setPointerLatency(open: false)
    }

    #if DEBUG
    /// The runner asks for the exit to be worked (a probe is waiting while frames are queued).
    func drainQueuedFrames() { drain() }

    /// The same drain as above, plus the measurement duties: it notes how long the radio stays full, and while a run that
    /// interleaves is going it lets `TransmitInterleave` pick between the next frame and the waiting probe (keyboard mode:
    /// four frames, then a probe; touchpad mode: four probes, then a frame). It also tells the runner when a frame left and
    /// when the queue ran empty.
    private func drainTracked(manager: CBPeripheralManager, characteristic: CBMutableCharacteristic, central: CBCentral) {
        let interleaving = measurement.wantsInterleave
        interleave.mode = measurement.transmitMode
        while true {
            let hasFrame = queue.pendingCount > 0
            let hasPacket = interleaving && measurement.hasWaitingPacket
            guard let source = interleave.choose(hasFrame: hasFrame, hasPacket: hasPacket) else { break }
            switch source {
            case .frame:
                var handedOne = false
                var refused = false
                queue.drain { frame in
                    if handedOne { return false }
                    guard manager.updateValue(frame, for: characteristic, onSubscribedCentrals: [central]) else {
                        refused = true
                        return false
                    }
                    handedOne = true
                    return true
                }
                if refused {
                    noteBlocked()
                    return
                }
                interleave.handed(.frame, otherWaiting: hasPacket)
                measurement.noteFrameHanded()
                if queue.pendingCount == 0 { measurement.noteQueueEmpty() }
            case .packet:
                guard measurement.offerPacket() else { return }
                interleave.handed(.packet, otherWaiting: hasFrame)
            }
        }
        measurement.pump()
    }
    #endif

    private static func diagnosticKey(_ kind: EventKind) -> (DiagnosticKeyKind, Int)? {
        switch kind {
        case .text(let text): (.text, text.utf8.count)
        case .backspace: (.backspace, 0)
        case .returnKey: (.return, 0)
        case .ping, .probe, .pointerOpen, .pointerClose: nil
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
            // Only the current host's selected UUID is advertised, so only that host connects. With no current host (nothing
            // paired, or no readable key) nothing is advertised at all.
            guard let pair = selectedPair else { return }
            let selected = CBUUID(nsuuid: SelectUUID.make(hostId: pair.host.id))
            manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [selected]])
        case .stopAdvertising:
            manager.stopAdvertising()
        case .removeServices:
            clearPendingService()
            manager.removeAllServices()
            KeyboardLifecycleLog.note(.removeAllServices)
            eventCharacteristic = nil
            queue.removeAll()
            // The connection went with the service; nothing about it may outlive it.
            dropConnectionState()
        }
    }

    /// Forgets the Mac connection: the bound central, the handshake and what the Mac last said. CoreBluetooth does not
    /// reliably report an unsubscribe when the radio goes away or the service is removed, so this must not wait for one;
    /// a stale authenticated handshake would otherwise lock out the Mac's next connection.
    private func dropConnectionState() {
        cancelProbe()
        binding.clear()
        subscribedCentral = nil
        resetLatency()
        handshake = nil
        latestStatus = nil
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
        let power = Self.map(peripheral.state)
        if power != .poweredOn {
            binding.powerChanged(power)
            dropConnectionState()
        }
        feed(.power(power))
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
        guard outcome == .bound else { return }
        beginConnection(with: central)
    }

    /// `central` is now the bound one: nothing of an earlier connection carries over, and a fresh handshake starts.
    private func beginConnection(with central: CBCentral) {
        // A subscription, even a repeat one from the same Mac, is a new connection: nothing of the old one carries over.
        cancelProbe()
        latestStatus = nil
        queue.removeAll()
        subscribedCentral = central
        DiagnosticEvent.centralSubscribed(maxUpdateLength: central.maximumUpdateValueLength).log()
        KeyboardLifecycleLog.note(.subscribed(maxUpdateValueLength: central.maximumUpdateValueLength))
        // Every host connection runs its own handshake with its own nonce; a recorded reply is useless on the next one.
        loadHosts()
        // A repeat subscription replaces the handshake without it ever being nil, so the old connection's channels go here.
        channels = nil
        pointerConnectionEnded()
        resetLatency()
        #if DEBUG
        measureConnectionEnded()
        applyLatency()
        #endif
        // A new link counts as activity: it starts at the default interval and slows down after ten quiet seconds.
        latencyPolicy.noteActivity(atMs: MonotonicClock.nowMs())
        reconcileLatency()
        handshake = PhoneHandshake(
            selected: selectedPair.map { (hostId: $0.host.id, pairKey: $0.pairKey) }, phoneNonce: Pairing.randomNonce())
        handshakeHostId = selectedPair?.host.id
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
        connectionLeft()
    }

    /// The bound central is gone (it unsubscribed, or a `hello` for another host released the binding): the connection's state
    /// goes with it and the keyboard advertises again.
    private func connectionLeft() {
        // Keys typed for the old connection are not replayed into a later one.
        cancelProbe()
        subscribedCentral = nil
        resetLatency()
        handshake = nil
        latestStatus = nil
        queue.removeAll()
        feed(.unsubscribed)
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        radioBlocked = false
        pointerSender?.radioReady()
        #if DEBUG
        if let since = blockedSince {
            blockedSince = nil
            measurement.noteBlocked(micros: MeasureClock.nowMicros() &- since)
        }
        #endif
        drain()
        #if DEBUG
        measurement.radioReady()
        #endif
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        // Prepared (long) writes arrive as pieces with offsets; the payload is the pieces in offset order.
        let pieces = requests.filter { $0.characteristic.uuid == Self.controlID }.sorted { $0.offset < $1.offset }
        var payload = Data()
        for piece in pieces { payload.append(piece.value ?? Data()) }
        #if DEBUG
        // A reply to a measurement probe: not JSON, opened by the runner with the measureM2P opener.
        if payload.first == CounterChannel.measureMagic {
            peripheral.respond(to: first, withResult: .success)
            if binding.shouldAcceptWrite(from: first.central.identifier) { measurement.handleReply(payload) }
            return
        }
        #endif
        guard !pieces.isEmpty, let message = try? ControlCodec.decode(payload) else {
            KeyboardLifecycleLog.note(.controlDecodeFailed(pieces: pieces.count, length: payload.count))
            peripheral.respond(to: first, withResult: .invalidAttributeValueLength)
            return
        }
        peripheral.respond(to: first, withResult: .success)
        if case .pairAccept = message { return }  // pairing happens in the host App, never in the keyboard
        // A `hello` is the one write a central other than the bound one may make: whether it is for the current host decides
        // who it is allowed to reach (docs/protocol/v4.md §6.3).
        if case .hello = message, !routeHello(message, from: first.central) { return }
        // The ATT request is answered either way; only the bound central's bytes reach the handshake.
        guard binding.shouldAcceptWrite(from: first.central.identifier) else { return }
        guard var current = handshake else { return }
        let wasAuthenticated = current.canSendEvents
        let output = current.receive(message)
        handshake = current
        switch output {
        case .none:
            break
        case .send(let reply):
            transmit(reply)
        case .authenticated:
            KeyboardLifecycleLog.note(.handshakeAuthenticated)
            channels = current.takeChannelSet()
            handshake = current
            onStateChange?(machine.state)
            onHandshake?(.authenticated)
        case .deliver(let inner):
            deliver(inner)
        case .failed:
            KeyboardLifecycleLog.note(.handshakeFailed(
                reason: current.failure?.reason ?? "unknown", failureLength: current.failure?.length,
                pieces: pieces.count, payloadLength: payload.count, wasAuthenticated: wasAuthenticated))
            // An unpaired keyboard already says so in the status line; only a failed proof needs a note.
            if pairKey != nil { onNote?("配對驗證失敗") }
            onStateChange?(machine.state)
            onHandshake?(.failed)
            // The Mac drops the connection, but iOS may keep the link and never report it. Publish the service again so
            // the keyboard does not sit "connected" forever. The Mac's skip list stops it from reconnecting meanwhile.
            if LinkRecovery.shouldResetAfterHandshakeFailure(hasPairKey: pairKey != nil) { resetLink() }
        }
    }

    /// Applies the §6.3 table to a `hello`. `true` when it goes on to the handshake of the bound central; `false` when it was
    /// answered with `notSelected` or ignored.
    private func routeHello(_ hello: ControlMessage, from central: CBCentral) -> Bool {
        let wasBound = binding.subscribed == central.identifier
        let disposition = binding.helloDisposition(
            from: central.identifier, hello: hello, currentHostId: selectedPair?.host.id,
            locked: handshake?.canSendEvents == true)
        switch disposition {
        case .ignore:
            return false
        case .replyNotSelected:
            // Plain, to this central only, nothing kept. This is the only thing any other central gets from the keyboard.
            notify(.notSelected, to: central)
            // The binding was released inside `helloDisposition` when the writer was the bound central: its handshake and
            // session go with it, and the keyboard advertises again as if it had unsubscribed.
            if wasBound { connectionLeft() }
            return false
        case .handshake:
            // The binding moved to a central that had not subscribed through the usual path (the bound connection was not
            // authenticated yet): it starts a fresh connection.
            if !wasBound { beginConnection(with: central) }
            return true
        }
    }

    /// One plain message to one central, outside the bound connection's queue. Best effort: when the radio is full the
    /// message is dropped and the host's handshake timeout takes over.
    private func notify(_ message: PeripheralMessage, to central: CBCentral) {
        guard let manager, let eventCharacteristic,
              let payload = try? PeripheralCodec.encode(message),
              let frames = try? FrameCodec.split(payload, messageId: messageId, maxFrameBytes: central.maximumUpdateValueLength)
        else { return }
        messageId &+= 1
        for frame in frames where !manager.updateValue(frame, for: eventCharacteristic, onSubscribedCentrals: [central]) {
            return
        }
    }

    /// An `ack`, `status` or `bye` the Mac sent after it was authenticated (opened from `sealed`).
    private func deliver(_ message: ControlMessage) {
        switch message {
        case .bye:
            // The Mac is leaving on purpose. iOS may never report the unsubscribe, so do not wait for it.
            KeyboardLifecycleLog.note(.byeReceived)
            resetLink()
            return
        case .status(let status):
            latestStatus = status
            reconcilePointer(with: status)
        case .ack(let ack):
            DiagnosticEvent.ackReceived(ack.result).log()
            // The answer to a touchpad switch is not a typed key: it opens or refuses the channel and says nothing else.
            if pointerEventIds.remove(ack.eventId) != nil {
                if ack.eventId == pointerOpenEventId {
                    pointerOpenEventId = nil
                    pointerOpenAnswered(ack.result)
                }
                return
            }
            sender.acknowledged(ack)
            // The pong for the liveness probe: the link is alive. Like the reconnect probe it is not a typed key.
            if ack.result == .pong, probe.pongReceived(eventId: ack.eventId) {
                probeTimer?.invalidate()
                probeTimer = nil
                KeyboardLifecycleLog.note(.probeAnswered)
                return
            }
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
