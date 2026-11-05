import Foundation
import RemoteKeyboardCore

/// Pure rules for what a new focus snapshot means for the session and for the status sent to the keyboard.
enum FocusTransition {
    static let maxAppNameLength = 24

    /// R17: a new snapshot that is editable and either follows a non-editable one or carries a new epoch.
    static func gainedEditable(previous: FocusSnapshot?, next: FocusSnapshot) -> Bool {
        guard next.editable else { return false }
        guard let previous else { return true }
        return !previous.editable || previous.epoch != next.epoch
    }

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

/// Wires focus changes to the receive session (D13) and to the status the keyboard shows. Everything that goes to or
/// comes from the keyboard passes through `ReceiverSecurity`.
@MainActor
final class ReceiverCoordinator: ObservableObject {
    private let central: ReceiverBLECentral
    private let security: ReceiverSecurity
    private var last: FocusSnapshot?

    private let focus: FocusMonitor
    private let pipeline: EventPipeline?
    private let pointer: PointerReceiver?

    #if DEBUG
    /// Whether the Receiver's measurement mode is on, for the status the keyboard reads. Debug builds only.
    var measureMode: () -> Bool = { false }
    /// Sees the text of every text event the moment it arrives, before it is queued (M7 checks the long text with it).
    var measureTextArrived: (@MainActor (String) -> Void)?
    #endif

    /// Does not hook anything up; call `start()` for the live wiring.
    /// - Parameter pipeline: receives every verified event from `security`. Nil leaves the security callbacks alone.
    /// - Parameter pointer: the touchpad. Its `pointerOpen` and `pointerClose` events are answered here at once, not queued
    ///   behind text; its grant goes into every status. Nil leaves the touchpad out (no grant, every open refused).
    init(
        focus: FocusMonitor, central: ReceiverBLECentral, security: ReceiverSecurity, pipeline: EventPipeline? = nil,
        pointer: PointerReceiver? = nil
    ) {
        self.focus = focus
        self.central = central
        self.security = security
        self.pipeline = pipeline
        self.pointer = pointer
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
            security.observeChannelSet { [weak pointer] channels in
                if let channels { pointer?.attach(channels) } else { pointer?.detach() }
            }
            pointer.onGrantChange = { [weak self] in self?.sendStatus() }
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
        case .pointerOpen(let grant): code = pointer?.handleOpen(grant: grant) ?? .notAuthorized
        case .pointerClose: code = pointer?.handleClose() ?? .posted
        default: return false
        }
        central.noteEvent()
        security.send(.ack(Ack(eventId: event.eventId, result: code)))
        return true
    }

    /// Stands in for the focus until the first read: nothing is editable, so the status is never `ready`.
    private static let placeholderSnapshot = FocusSnapshot(axTrusted: true, frontmostPID: 0, appName: nil, editable: false, epoch: 0)

    func focusChanged(_ next: FocusSnapshot) {
        let previous = last
        last = next
        if FocusTransition.gainedEditable(previous: previous, next: next) { central.focusGainedEditable() }
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
