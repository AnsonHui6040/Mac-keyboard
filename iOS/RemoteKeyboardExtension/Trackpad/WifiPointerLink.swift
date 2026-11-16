import Foundation
import Network

/// The iPhone's end of the Wi-Fi path (spec W1, W15; docs/protocol/v4.md §8.6): a UDP listener that the Receiver's probes
/// arrive at, and the send side that goes back to the source of a probe.
///
/// It only moves datagrams. Whether a datagram is a real probe is decided by the owner (`PointerPathMonitor` and the probe
/// opener, in `KeyboardBLEPeripheral`), which then calls `adopt(_:)`; until then no datagram is ever sent anywhere. The listener
/// exists only while the touchpad channel is being opened or open, and nothing here logs an address or a byte.
///
/// Isolation: the class is `@MainActor`, like the peripheral that owns it, and every Network callback is delivered on the main
/// queue (`start(queue: .main)`), so each handler re-enters the actor with `MainActor.assumeIsolated` (it traps if that were ever
/// wrong, instead of racing). A `NWConnection` is only touched from here.
@MainActor
final class WifiPointerLink {
    /// The listener has this long to become ready; after that the owner is told there is no port.
    static let readyTimeout: TimeInterval = 0.5
    /// Remote endpoints kept at once. Anyone on the network can start a flow by sending a datagram to the port; the oldest one that
    /// is not the send target makes room, so a flood cannot push the Receiver out.
    static let maxInbound = 16

    /// A datagram came in from `endpoint`. The owner opens it and calls `adopt(_:)` when it was a valid probe.
    var onDatagram: ((Data, NWEndpoint) -> Void)?
    /// The send target broke (a send failed, or its flow failed or is waiting, for example without local network permission).
    var onSendFailure: (() -> Void)?

    private struct Inbound {
        let connection: NWConnection
        var isReady = false
    }

    private var listener: NWListener?
    private(set) var port: UInt16?
    private var isStopped = false
    private var pendingReady: [@MainActor (UInt16?) -> Void] = []
    private var readyTimer: Timer?
    /// Oldest first, so the oldest can make room.
    private var order: [NWEndpoint] = []
    private var inbound: [NWEndpoint: Inbound] = [:]
    private var target: NWEndpoint?

    // MARK: Listener

    /// Reports the listener's UDP port once, or `nil` when it was not ready within `readyTimeout` (or could not start). Called
    /// again while the listener runs, the port is reported at once.
    func start(onReady: @escaping @MainActor (UInt16?) -> Void) {
        guard !isStopped else { return }
        if let port {
            onReady(port)
            return
        }
        pendingReady.append(onReady)
        guard listener == nil else { return }
        // The Receiver is on the local network; a flow over the mobile network is never wanted.
        let parameters = NWParameters.udp
        parameters.prohibitedInterfaceTypes = [.cellular]
        guard let listener = try? NWListener(using: parameters) else {
            finishReady(nil)
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.listenerChanged(state) }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated { self?.accept(connection) }
        }
        let timer = Timer(timeInterval: Self.readyTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishReady(nil) }
        }
        RunLoop.main.add(timer, forMode: .common)
        readyTimer = timer
        listener.start(queue: .main)
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let value = listener?.port?.rawValue else { return }
            port = value
            finishReady(value)
        case .failed, .cancelled:
            // A listener that failed after it was ready is gone for good: its port must not be offered again, so a later
            // `start` begins a new one. Its flows belonged to it.
            discardListener()
            finishReady(nil)
        default:
            break
        }
    }

    private func discardListener() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        port = nil
        for endpoint in order { remove(endpoint) }
    }

    private func finishReady(_ value: UInt16?) {
        readyTimer?.invalidate()
        readyTimer = nil
        let handlers = pendingReady
        pendingReady.removeAll()
        for handler in handlers { handler(value) }
    }

    /// Cancels the listener and every flow and forgets the target. Nothing is called back afterwards.
    func stop() {
        isStopped = true
        readyTimer?.invalidate()
        readyTimer = nil
        pendingReady.removeAll()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for entry in inbound.values {
            entry.connection.stateUpdateHandler = nil
            entry.connection.cancel()
        }
        inbound.removeAll()
        order.removeAll()
        target = nil
        port = nil
        onDatagram = nil
        onSendFailure = nil
    }

    // MARK: Flows

    private func accept(_ connection: NWConnection) {
        guard !isStopped else {
            connection.cancel()
            return
        }
        let endpoint = connection.endpoint
        if inbound[endpoint] != nil { remove(endpoint) }
        while order.count >= Self.maxInbound, let victim = order.first(where: { $0 != target }) { remove(victim) }
        inbound[endpoint] = Inbound(connection: connection)
        order.append(endpoint)
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.flowChanged(state, endpoint: endpoint, connection: connection) }
        }
        connection.start(queue: .main)
        receive(on: connection, endpoint: endpoint)
    }

    private func receive(on connection: NWConnection, endpoint: NWEndpoint) {
        connection.receiveMessage { [weak self] data, _, _, error in
            MainActor.assumeIsolated {
                guard let self, self.inbound[endpoint]?.connection === connection else { return }
                if let data, !data.isEmpty { self.onDatagram?(data, endpoint) }
                // The callback may have stopped the link or replaced this flow.
                guard self.inbound[endpoint]?.connection === connection else { return }
                if error == nil {
                    self.receive(on: connection, endpoint: endpoint)
                } else {
                    self.flowEnded(endpoint)
                }
            }
        }
    }

    private func flowChanged(_ state: NWConnection.State, endpoint: NWEndpoint, connection: NWConnection) {
        guard inbound[endpoint]?.connection === connection else { return }
        switch state {
        case .ready:
            inbound[endpoint]?.isReady = true
        case .waiting:
            if endpoint == target {
                // Local network permission refused: sends can never work. Any other wait may pass, so the target stays and
                // `send` just declines until it is ready again.
                if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                    flowEnded(endpoint)
                } else {
                    inbound[endpoint]?.isReady = false
                }
            } else {
                remove(endpoint)
            }
        case .failed, .cancelled:
            flowEnded(endpoint)
        default:
            break
        }
    }

    /// A flow went away. Only the loss of the send target is news to the owner.
    private func flowEnded(_ endpoint: NWEndpoint) {
        let wasTarget = endpoint == target
        remove(endpoint)
        if wasTarget { onSendFailure?() }
    }

    private func remove(_ endpoint: NWEndpoint) {
        if let entry = inbound.removeValue(forKey: endpoint) {
            entry.connection.stateUpdateHandler = nil
            entry.connection.cancel()
        }
        order.removeAll { $0 == endpoint }
        if target == endpoint { target = nil }
    }

    // MARK: Send side

    /// The flow of `endpoint` becomes the send target: the owner has just opened a valid probe that came from it.
    func adopt(_ endpoint: NWEndpoint) {
        guard !isStopped, inbound[endpoint] != nil else { return }
        target = endpoint
    }

    /// Forgets the target and closes its flow, so the next probe starts a fresh one.
    func dropTarget() {
        if let target { remove(target) }
    }

    /// Hands one datagram to the target's flow. `false` when there is no target or its flow is not ready yet: the packet is then not
    /// sent, and that is not a failure (nothing is dropped, no pause starts). A real failure, a send that completes with an error or
    /// a flow that fails or is refused the local network, comes back through `onSendFailure`.
    func send(_ packet: Data) -> Bool {
        guard !isStopped, let target, let entry = inbound[target], entry.isReady else { return false }
        let connection = entry.connection
        connection.send(content: packet, contentContext: .defaultMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            MainActor.assumeIsolated {
                guard let self, self.inbound[target]?.connection === connection else { return }
                self.flowEnded(target)
            }
        })
        return true
    }
}
