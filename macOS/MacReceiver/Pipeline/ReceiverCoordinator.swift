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

/// Wires focus changes to the receive session (D13) and to the status the keyboard shows.
@MainActor
final class ReceiverCoordinator: ObservableObject {
    private let central: ReceiverBLECentral
    private var last: FocusSnapshot?

    private let focus: FocusMonitor

    /// Does not hook anything up; call `start()` for the live wiring.
    init(focus: FocusMonitor, central: ReceiverBLECentral) {
        self.focus = focus
        self.central = central
    }

    func start() {
        focus.onChange = { [weak self] snapshot in self?.focusChanged(snapshot) }
        central.onLinkReady = { [weak self] in self?.sendStatus() }
    }

    func focusChanged(_ next: FocusSnapshot) {
        let previous = last
        last = next
        if FocusTransition.gainedEditable(previous: previous, next: next) { central.focusGainedEditable() }
        if FocusTransition.statusChanged(previous: previous, next: next) { sendStatus() }
    }

    func sendStatus() {
        guard let last else { return }
        central.send(.status(FocusTransition.status(for: last)))
    }
}
