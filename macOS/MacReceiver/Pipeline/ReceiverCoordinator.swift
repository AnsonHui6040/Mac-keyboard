import Foundation
import RemoteKeyboardCore

/// Pure rules for what a new focus snapshot means for the status sent to the keyboard. Focus does not affect receiving (D29).
enum FocusTransition {
    static let maxAppNameLength = 24

    /// The keyboard must hear about a change of epoch, editable state, app, trust or blocked input (Secure Input can turn
    /// on or off with no focus change at all).
    static func statusChanged(previous: FocusSnapshot?, next: FocusSnapshot) -> Bool {
        guard let previous else { return true }
        return previous.epoch != next.epoch || previous.editable != next.editable
            || previous.appName != next.appName || previous.axTrusted != next.axTrusted
            || previous.inputBlocked != next.inputBlocked
    }

    /// `ready` only when the focused field can take text and input is not blocked. The name is cut so the write stays far below one ATT payload.
    static func status(for snapshot: FocusSnapshot, pointerGrant: UInt32? = nil) -> ReceiverStatus {
        ReceiverStatus(
            ready: snapshot.axTrusted && snapshot.editable && !snapshot.inputBlocked,
            appName: snapshot.appName.map { String($0.prefix(maxAppNameLength)) },
            focusEpoch: snapshot.epoch,
            trusted: snapshot.axTrusted,
            pointerGrant: pointerGrant,
            inputBlocked: snapshot.inputBlocked
        )
    }

    #if DEBUG
    /// The same status with the Receiver's measurement mode. A Release build has no such overload, so its status never says `measure`.
    static func status(for snapshot: FocusSnapshot, measure: Bool, pointerGrant: UInt32? = nil) -> ReceiverStatus {
        let base = status(for: snapshot, pointerGrant: pointerGrant)
        return ReceiverStatus(
            ready: base.ready, appName: base.appName, focusEpoch: base.focusEpoch, trusted: base.trusted, measure: measure,
            pointerGrant: pointerGrant, inputBlocked: base.inputBlocked)
    }
    #endif
}

/// Wires focus changes to the status the keyboard shows (receiving itself does not depend on focus, D29). Everything that goes to or
/// comes from the keyboard passes through `ReceiverSecurity`.
@MainActor
final class ReceiverCoordinator: ObservableObject {
    private let central: ReceiverBLECentral
    private let security: ReceiverSecurity
    private var last: FocusSnapshot?

    private let focus: FocusMonitor
    private let pipeline: EventPipeline?
    private let pointer: PointerReceiver?
    private let wifi: WifiProbeLink?
    /// The channel set of the authenticated connection, for the probe sealer. `nil` without one.
    private var channels: ChannelSet?

    #if DEBUG
    /// Whether the Receiver's measurement mode is on, for the status the keyboard reads. Debug builds only.
    var measureMode: () -> Bool = { false }
    /// Sees the text of every text event the moment it arrives, before it is queued (M7 checks the long text with it).
    var measureTextArrived: (@MainActor (String) -> Void)?
    #endif

    /// Does not hook anything up; call `start()` for the live wiring.
    /// - Parameter pipeline: receives every verified event from `security`. Nil leaves the security callbacks alone.
    /// - Parameter wifi: the Wi-Fi assist (spec D30). It probes while the touchpad channel is open with a valid `wifi` offer; its UDP
    ///   packets go to the same touchpad as the Bluetooth ones. Nil leaves it out, and `wifi` in a `pointerOpen` is ignored.
    /// - Parameter pointer: the touchpad. Its `pointerOpen` and `pointerClose` events are answered here at once, not queued
    ///   behind text; its grant goes into every status. Nil leaves the touchpad out (no grant, every open refused).
    init(
        focus: FocusMonitor, central: ReceiverBLECentral, security: ReceiverSecurity, pipeline: EventPipeline? = nil,
        pointer: PointerReceiver? = nil, wifi: WifiProbeLink? = nil
    ) {
        self.focus = focus
        self.central = central
        self.security = security
        self.pipeline = pipeline
        self.pointer = pointer
        self.wifi = wifi
    }

    func start() {
        focus.onChange = { [weak self] snapshot in self?.focusChanged(snapshot) }
        // The first status goes out only after the phone proved the pair key, and then sealed.
        security.onAuthenticated = { [weak self] in
            self?.focus.setLinkActive(true)
            self?.sendStatus()
        }
        // Without an authenticated iPhone nothing can be typed, so focus is polled slowly.
        security.onLinkLost = { [pipeline, weak self] in
            self?.focus.setLinkActive(false)
            // Queued keys of a lost link are dropped; what the pipeline has already processed stays remembered.
            pipeline?.discardQueued()
        }
        if let pointer {
            security.observeChannelSet { [weak self, weak pointer] channels in
                // Whatever ended the connection (link lost, failed handshake, a new one), its probes end with it.
                self?.wifi?.stop(why: "disconnect")
                self?.channels = channels
                if let channels { pointer?.attach(channels) } else { pointer?.detach() }
            }
            pointer.onGrantChange = { [weak self] in
                // A new or withdrawn grant ends whatever was opened with the old one, and the probes with it.
                self?.wifi?.stop(why: "grant_changed")
                self?.sendStatus()
            }
            wifi?.onPointerPacket = { [weak pointer] in pointer?.handle($0, via: .udp) }
            wifi?.isChannelOpen = { [weak pointer] in pointer?.isOpen ?? false }
        }
        if let pipeline {
            security.onEvent = { [pipeline, weak self] event in
                #if DEBUG
                if case .text(let text) = event.kind { self?.measureTextArrived?(text) }
                #endif
                if self?.answerPointerSwitch(event) == true { return }
                pipeline.submit(event)
            }
            security.onMalformed = { [pipeline] in pipeline.submitMalformed() }
        }
    }

    /// A `pointerOpen` or `pointerClose` is handled and acknowledged here, in the moment it arrives, so a text that is still
    /// being typed (an input source switch can take hundreds of milliseconds) never delays it. Returns whether it was one.
    private func answerPointerSwitch(_ event: KeyboardEvent) -> Bool {
        let code: AckCode
        switch event.kind {
        case .pointerOpen(let grant, let offer):
            code = pointer?.handleOpen(grant: grant) ?? .notAuthorized
            updateProbing(after: code, offer: offer)
        case .pointerClose:
            code = pointer?.handleClose() ?? .posted
            wifi?.stop(why: "close")
        default: return false
        }
        security.send(.ack(Ack(eventId: event.eventId, result: code)))
        return true
    }

    /// What a `pointerOpen` means for the Wi-Fi probes: they start (or move to the new targets) when the channel opened and the
    /// offer is valid; any other outcome ends them (spec W8). An offer the phone wrote wrongly arrives here as `nil`.
    private func updateProbing(after code: AckCode, offer: WifiOffer?) {
        guard let wifi else { return }
        guard code == .posted else { return wifi.stop(why: "refused") }
        guard let offer, let channels else { return wifi.stop(why: "no_wifi") }
        wifi.start(offer: offer, sealer: channels.sealer(.wifiProbe))
    }

    /// Stands in for the focus until the first read: nothing is editable, so the status is never `ready`.
    private static let placeholderSnapshot = FocusSnapshot(axTrusted: true, frontmostPID: 0, appName: nil, editable: false, epoch: 0)

    func focusChanged(_ next: FocusSnapshot) {
        let previous = last
        last = next
        if FocusTransition.statusChanged(previous: previous, next: next) { sendStatus() }
    }

    func sendStatus() {
        let grant = pointer?.grant
        // No focus snapshot yet: with the touchpad wired, a not-ready status still goes out, so the phone gets the grant (or
        // learns that it is gone) without waiting for a focus change. Without the touchpad nothing is said yet, as before.
        guard let last = last ?? (pointer == nil ? nil : Self.placeholderSnapshot) else { return }
        #if DEBUG
        security.send(.status(FocusTransition.status(for: last, measure: measureMode(), pointerGrant: grant)))
        #else
        security.send(.status(FocusTransition.status(for: last, pointerGrant: grant)))
        #endif
    }
}
