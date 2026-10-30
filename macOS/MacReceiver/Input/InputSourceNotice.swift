import Carbon.HIToolbox
import Foundation
import RemoteKeyboardCore

/// What the panel says when the Mac stayed on the ASCII layout because the original input source could not be selected
/// again. Cleared only once the current input source is no longer ABC.
@MainActor
final class InputSourceNotice: ObservableObject {
    static let restoreFailedText = "輸入法未能切回，請手動切換"

    @Published private(set) var message: String?
    private let currentID: @MainActor () -> String

    init(currentID: @escaping @MainActor () -> String = { TISInputSourceController().currentID() }) {
        self.currentID = currentID
    }

    private var observer: NSObjectProtocol?

    /// `restoredOK == false` raises the message. A good report clears it only when the current source is no longer ABC:
    /// an injection that found ABC already active switches nothing, so it says nothing about the user's own switch.
    func report(restoredOK: Bool) {
        if !restoredOK {
            message = Self.restoreFailedText
        } else {
            sourceChanged()
        }
    }

    /// The input source may have changed; drops the message once it is no longer ABC.
    func sourceChanged() {
        if message != nil, currentID() != InputSourceSwitcher.asciiID { message = nil }
    }

    /// Listens for the system's selected-input-source change so a manual switch clears the message at once.
    func startObserving() {
        guard observer == nil else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sourceChanged() }
        }
    }
}
