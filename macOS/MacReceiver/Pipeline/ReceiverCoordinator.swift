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

    /// The keyboard must hear about a change of epoch, editable state, app or trust.
    static func statusChanged(previous: FocusSnapshot?, next: FocusSnapshot) -> Bool {
        guard let previous else { return true }
        return previous.epoch != next.epoch || previous.editable != next.editable
            || previous.appName != next.appName || previous.axTrusted != next.axTrusted
    }

    /// `ready` only when the focused field can take text. The name is cut so the write stays far below one ATT payload.
    static func status(for snapshot: FocusSnapshot) -> ReceiverStatus {
        ReceiverStatus(
            ready: snapshot.axTrusted && snapshot.editable,
            appName: snapshot.appName.map { String($0.prefix(maxAppNameLength)) },
            focusEpoch: snapshot.epoch
        )
    }
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

    /// Does not hook anything up; call `start()` for the live wiring.
    /// - Parameter pipeline: receives every verified event from `security`. Nil leaves the security callbacks alone.
    init(focus: FocusMonitor, central: ReceiverBLECentral, security: ReceiverSecurity, pipeline: EventPipeline? = nil) {
        self.focus = focus
        self.central = central
        self.security = security
        self.pipeline = pipeline
    }

    func start() {
        focus.onChange = { [weak self] snapshot in self?.focusChanged(snapshot) }
        // The first status goes out only after the phone proved the pair key, and then sealed.
        security.onAuthenticated = { [weak self] in self?.sendStatus() }
        if let pipeline {
            security.onEvent = { [pipeline] event in pipeline.submit(event) }
            security.onMalformed = { [pipeline] in pipeline.submitMalformed() }
            // Queued keys of a lost link are dropped; what the pipeline has already processed stays remembered.
            security.onLinkLost = { [pipeline] in pipeline.discardQueued() }
        }
    }

    func focusChanged(_ next: FocusSnapshot) {
        let previous = last
        last = next
        if FocusTransition.gainedEditable(previous: previous, next: next) { central.focusGainedEditable() }
        if FocusTransition.statusChanged(previous: previous, next: next) { sendStatus() }
    }

    func sendStatus() {
        guard let last else { return }
        security.send(.status(FocusTransition.status(for: last)))
    }
}
