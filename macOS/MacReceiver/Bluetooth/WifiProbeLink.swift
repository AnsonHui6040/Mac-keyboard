import Foundation
import Network
import OSLog
import RemoteKeyboardCore

/// One place a probe goes to: an IPv4 address of the iPhone and the UDP port of its listener, exactly as the phone wrote them.
struct WifiTarget: Hashable, Sendable {
    let address: String
    let port: UInt16
}

/// The datagram I/O of the Wi-Fi assist. The link decides what is sent when and what is let in; this only moves bytes.
@MainActor
protocol WifiProbeTransport: AnyObject {
    /// One datagram that came back from `target`. Only datagrams of the targets given to `open` are reported.
    var onDatagram: (@MainActor (WifiTarget, Data) -> Void)? { get set }
    /// These are now the targets, replacing any earlier ones.
    func open(_ targets: [WifiTarget])
    /// The same datagram to every target that is open.
    func send(_ datagram: Data)
    /// Nothing is sent or reported any more.
    func close()
}

/// Where the log lines go: one line per call, event names and counts only.
typealias WifiProbeLog = @MainActor (String) -> Void

/// Makes a repeating timer; the result cancels it.
typealias WifiProbeTimerFactory = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

/// The Wi-Fi assist of the Mac Receiver (docs/protocol/v4.md section 8.6, spec W1, W8 to W10, W16).
///
/// While the pointer channel is open and its `pointerOpen` carried a valid `wifi` offer, the Receiver sends the iPhone one freshly
/// sealed probe (16 zero bytes under the connection's `.wifiProbe` key) at once and then every 250 ms, to every address of the
/// offer. The iPhone answers a probe it can open by sending its `0x03` packets to the probe's source, and those datagrams come
/// back here: only one from a probed address and port, exactly 41 bytes long and starting with `0x03`, is handed on.
///
/// This type owns the schedule and the filter; the caller (the coordinator) decides when probing starts and stops, and the
/// transport only moves bytes. Everything runs on the main actor, like the BLE side.
///
/// The log holds event names and counts only: never an address, never a byte.
@MainActor
final class WifiProbeLink {
    /// Provisional (spec section 8, no measurement behind it): one probe per address every 250 ms. It keeps the phone's path
    /// alive within its 1 s window and a Windows firewall's state for the probed address.
    static let probeInterval: TimeInterval = 0.25
    /// A pointer packet: 9 bytes of header, 16 of payload, 16 of tag.
    static let pointerDatagramLength = 41

    /// Receives each datagram that passed the filter, whole. It is a `0x03` packet that came over UDP.
    var onPointerPacket: (@MainActor (Data) -> Void)?
    /// Asked at every tick: probes do not outlive the pointer channel, whatever ended it.
    var isChannelOpen: (@MainActor () -> Bool)?
    private(set) var isProbing = false

    private let transport: WifiProbeTransport
    private let makeTimer: WifiProbeTimerFactory
    private let log: WifiProbeLog
    private var targets: Set<WifiTarget> = []
    private var sealer: ChannelSealer?
    private var cancelTimer: (() -> Void)?
    private var droppedForSource = 0
    private var droppedForShape = 0

    init(
        transport: WifiProbeTransport, makeTimer: @escaping WifiProbeTimerFactory = WifiProbeLink.systemTimer,
        log: @escaping WifiProbeLog = WifiProbeLink.systemLog
    ) {
        self.transport = transport
        self.makeTimer = makeTimer
        self.log = log
        transport.onDatagram = { [weak self] source, datagram in self?.receive(datagram, from: source) }
    }

    private static let osLog = Logger(subsystem: "com.ansonhui.remotekeyboard.receiver", category: "wifi")

    /// Common-mode timers keep firing while the menu bar window is open.
    static func systemTimer(_ interval: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
        let timer = CommonModeTimer.make(interval, repeats: true, fire)
        return { timer.invalidate() }
    }

    static func systemLog(_ line: String) { osLog.info("\(line, privacy: .public)") }

    // MARK: Start and stop

    /// The targets are now the addresses of `offer` (replacing any earlier ones) and the first probe goes out at once. `sealer`
    /// is the connection's probe sealer: its counter runs for as long as the connection lasts, so no probe is a replay of another.
    func start(offer: WifiOffer, sealer: ChannelSealer) {
        cancelTimer?()
        // An address the phone wrote twice is one target: one connection, one probe.
        var seen: Set<WifiTarget> = []
        let list = offer.addrs.map { WifiTarget(address: $0, port: offer.port) }.filter { seen.insert($0).inserted }
        targets = seen
        self.sealer = sealer
        isProbing = true
        transport.open(list)
        log("wifi_probe_start targets=\(list.count)")
        sendProbe()
        cancelTimer = makeTimer(Self.probeInterval) { [weak self] in self?.tick() }
    }

    /// No more probes and no more datagrams. Says why when there was anything to stop; otherwise silent.
    func stop(why: String) {
        guard isProbing else { return }
        isProbing = false
        cancelTimer?()
        cancelTimer = nil
        transport.close()
        targets = []
        sealer = nil
        log("wifi_probe_stop why=\(why)")
        if droppedForSource + droppedForShape > 0 { log("wifi_drops source=\(droppedForSource) shape=\(droppedForShape)") }
        droppedForSource = 0
        droppedForShape = 0
    }

    private func tick() {
        guard isProbing else { return }
        if let isChannelOpen, !isChannelOpen() { return stop(why: "closed") }
        sendProbe()
    }

    private func sendProbe() {
        guard let sealer else { return }
        do {
            transport.send(try sealer.seal(Data(count: 16)))
        } catch {
            log("wifi_seal_failed")
        }
    }

    // MARK: Datagrams (spec W9)

    private func receive(_ datagram: Data, from source: WifiTarget) {
        guard isProbing else { return }
        guard targets.contains(source) else {
            droppedForSource += 1
            return
        }
        guard datagram.count == Self.pointerDatagramLength, datagram.first == CounterChannel.Kind.pointer.magic else {
            droppedForShape += 1
            return
        }
        onPointerPacket?(datagram)
    }
}

/// The real datagram I/O, on Network.framework: one UDP `NWConnection` per target.
///
/// The Receiver sends first (spec W1), and a connected UDP socket takes datagrams only from the endpoint it was connected to, so the
/// phone's answers arrive on the very connection that probed it. That is the source filter of spec W9 at the socket, and the link
/// checks the source again. All callbacks run on the main queue.
///
/// **A receive path can die while the connection looks fine.** One zero-length datagram on a connected UDP connection ends its
/// message stream: the receive that got it reports no data and `isComplete`, and every receive after it fails with ENODATA while the
/// state stays `ready`. Anybody who can spoof the phone's address could freeze the touchpad with one packet. So a receive that fails,
/// or ends with nothing and `isComplete`, and a connection that reaches `failed`, all count as a dead receive path: that target's
/// connection is cancelled and made again (a new local port), at most once per `rebuildInterval` for each target. Until it is made
/// again nothing is sent to that target. The phone answers a probe to its source, so the next probe on the new connection is what
/// brings the answers back.
///
/// Nothing here is fatal. A connection that cannot be made, a send that fails and a path that waits (the Mac has not allowed the
/// local network, spec F4) are each written once per `open` as a fixed word, never an address, and the Receiver goes on over
/// Bluetooth.
@MainActor
final class NWWifiProbeTransport: WifiProbeTransport {
    var onDatagram: (@MainActor (WifiTarget, Data) -> Void)?

    /// One target: its connection (`nil` while the receive path is dead and the new one is not yet made), which one it is, and when
    /// it was made.
    private struct Slot {
        var connection: NWConnection?
        var serial = 0
        var builtAt: ContinuousClock.Instant?
    }

    private let log: WifiProbeLog
    private let rebuildInterval: TimeInterval
    private var slots: [WifiTarget: Slot] = [:]
    /// Bumped by every `open` and `close`: a callback of an earlier set sees a different number and does nothing.
    private var generation = 0
    private var reported: Set<String> = []
    private var rebuildsThisOpen = 0

    /// Targets with a connection that can send and receive right now.
    var liveConnectionCount: Int { slots.values.filter { $0.connection != nil }.count }
    /// Connections made again since this transport was made.
    private(set) var rebuilds = 0

    init(log: @escaping WifiProbeLog = WifiProbeLink.systemLog, rebuildInterval: TimeInterval = 0.25) {
        self.log = log
        self.rebuildInterval = rebuildInterval
    }

    func open(_ targets: [WifiTarget]) {
        close()
        for target in targets where slots[target] == nil {
            guard IPv4Address(target.address) != nil, NWEndpoint.Port(rawValue: target.port) != nil else {
                report("bad_target")
                continue
            }
            slots[target] = Slot()
            build(target)
        }
    }

    func send(_ datagram: Data) {
        let current = generation
        for slot in slots.values {
            slot.connection?.send(content: datagram, completion: .contentProcessed { [weak self] error in
                guard let error else { return }
                MainActor.assumeIsolated {
                    guard let self, current == self.generation else { return }
                    self.report("send_\(Self.word(error))")
                }
            })
        }
    }

    func close() {
        generation += 1
        if rebuildsThisOpen > 1 { log("wifi_path rebuilds=\(rebuildsThisOpen)") }
        rebuildsThisOpen = 0
        reported = []
        for slot in slots.values {
            slot.connection?.stateUpdateHandler = nil
            slot.connection?.cancel()
        }
        slots = [:]
    }

    // MARK: Connections

    /// A new connection for `target`, which must have a slot and no connection.
    private func build(_ target: WifiTarget) {
        guard var slot = slots[target], slot.connection == nil,
              let address = IPv4Address(target.address), let port = NWEndpoint.Port(rawValue: target.port) else { return }
        slot.serial += 1
        let serial = slot.serial
        let current = generation
        let connection = NWConnection(host: .ipv4(address), port: port, using: .udp)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            MainActor.assumeIsolated { self?.stateChanged(state, of: connection, target: target, serial: serial, generation: current) }
        }
        slot.connection = connection
        slot.builtAt = .now
        slots[target] = slot
        connection.start(queue: .main)
        receive(on: connection, target: target, serial: serial, generation: current)
    }

    /// The receive path of this connection is dead: cancel it, send nothing to the target, and make a new connection once
    /// `rebuildInterval` has passed since the last one was made.
    private func markDead(_ target: WifiTarget, serial: Int, generation current: Int) {
        guard current == generation, var slot = slots[target], slot.serial == serial, let connection = slot.connection else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        slot.connection = nil
        slots[target] = slot
        report("rebuild")
        let waited = slot.builtAt.map { $0.duration(to: .now).inSeconds } ?? rebuildInterval
        let delay = max(0, rebuildInterval - waited)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, current == self.generation, self.slots[target]?.connection == nil, self.slots[target] != nil else { return }
                self.rebuilds += 1
                self.rebuildsThisOpen += 1
                self.build(target)
            }
        }
    }

    // MARK: Callbacks

    private func receive(on connection: NWConnection, target: WifiTarget, serial: Int, generation current: Int) {
        connection.receiveMessage { [weak self, weak connection] data, context, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, let connection, current == self.generation, self.slots[target]?.serial == serial else { return }
                if let error {
                    self.report("receive_\(Self.word(error))")
                    return self.markDead(target, serial: serial, generation: current)
                }
                if data?.isEmpty ?? true {
                    // A zero-length datagram ends the stream of a connected UDP connection (see the type's comment).
                    if isComplete || context?.isFinal == true { return self.markDead(target, serial: serial, generation: current) }
                } else if let data {
                    self.onDatagram?(target, data)
                }
                self.receive(on: connection, target: target, serial: serial, generation: current)
            }
        }
    }

    private func stateChanged(
        _ state: NWConnection.State, of connection: NWConnection?, target: WifiTarget, serial: Int, generation current: Int
    ) {
        guard current == generation, slots[target]?.serial == serial else { return }
        switch state {
        case .waiting:
            // No API says whether the local network is allowed; a path that waits for this reason says it (TN3179).
            report(connection?.currentPath?.unsatisfiedReason == .localNetworkDenied ? "local_network_denied" : "waiting")
        case .failed(let error):
            report("failed_\(Self.word(error))")
            markDead(target, serial: serial, generation: current)
        default:
            break
        }
    }

    /// One line per reason per `open`: a path that fails every 250 ms must not fill the log.
    private func report(_ reason: String) {
        guard reported.insert(reason).inserted else { return }
        log("wifi_path \(reason)")
    }

    /// A fixed word for an error; the text of an `NWError` can hold an address.
    private static func word(_ error: NWError) -> String {
        switch error {
        case .posix(let code): "posix\(code.rawValue)"
        case .dns: "dns"
        case .tls: "tls"
        default: "other"
        }
    }
}

private extension Duration {
    var inSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
