import CoreGraphics
import Foundation
import RemoteKeyboardCore
import os

/// The keyboard side of the handwriting input method: owns the `HandwritingSession` (strokes, candidates, keys) and
/// the model status. The model comes from the host app through `ModelImporter`. The controller feeds it keys and ink
/// and routes what it commits through the `InputRouter`.
///
/// Memory: the recognizer is created when the Chinese page appears and dropped when the keyboard disappears (ML Kit
/// with the model loaded peaked at about 86 MB of the 177 MB limit in the O7 spike).
/// Privacy: ink, candidates, context and committed text are never logged; only counts, durations and status.
@MainActor
final class ChineseInputCoordinator {
    enum ModelStatus: Equatable {
        /// The Chinese page is not active, or the model is being checked (nothing to show yet).
        case idle
        /// Copying the model the host app put in the App Group.
        case importing
        case ready
        /// No model in the keyboard and none to import: the user has to download it in the app.
        case missing
    }

    let session = HandwritingSession()
    private(set) var modelStatus: ModelStatus = .idle
    /// Candidates or model status changed.
    var onChange: (() -> Void)? {
        didSet { session.onChange = onChange }
    }
    /// The writing view should drop its ink.
    var onClearInk: (() -> Void)? {
        didSet { session.onClearInk = onClearInk }
    }

    private let makeRecognizer: () -> (any HandwritingRecognizing)?
    private var preparing: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.ansonhui.remotekeyboard", category: "handwriting")

    var candidates: [String] { session.candidates }

    init(makeRecognizer: @escaping () -> (any HandwritingRecognizing)? = { MLKitRecognizer() }) {
        self.makeRecognizer = makeRecognizer
        session.onRecognizerError = { [weak self] error in self?.recognizerFailed(error) }
    }

    // MARK: Lifecycle

    /// The Chinese page is on screen. Brings the model in line with the host app's copy, then loads the recognizer.
    /// Runs every time the keyboard appears (the recognizer is dropped when it disappears), so a model downloaded or
    /// deleted in the app since the last time is noticed.
    func activate() {
        guard !session.hasRecognizer, preparing == nil else { return }
        preparing = Task { [weak self] in
            var outcome = ModelImporter.Outcome.cancelled
            repeat {
                outcome = await ModelImporter.shared.prepare(onImportStart: { [weak self] in
                    Task { @MainActor in self?.importStarted() }
                })
            } while outcome == .cancelled && !Task.isCancelled
            guard let self, !Task.isCancelled else { return }
            self.preparing = nil
            switch outcome {
            case .ready: self.becomeReady()
            case .missing, .cancelled: self.setStatus(.missing)
            }
        }
    }

    /// The keyboard disappeared: free the recognizer, stop an import in progress, forget composition and history.
    func deactivate() {
        preparing?.cancel()
        preparing = nil
        session.deactivate()
        setStatus(.idle)
    }

    /// Drops ink and candidates (the user left the Chinese page).
    func resetComposition() {
        session.reset()
    }

    /// Forgets what was committed (mode switch).
    func resetHistory() {
        session.resetHistory()
    }

    // MARK: Private

    private func importStarted() {
        guard preparing != nil, modelStatus == .idle else { return }
        setStatus(.importing)
    }

    private func becomeReady() {
        guard let made = makeRecognizer() else {
            setStatus(.missing)
            return
        }
        session.setRecognizer(made)
        setStatus(.ready)
    }

    /// An error that says the model is gone or damaged drops the keyboard's copy; the next appearance imports again.
    private func recognizerFailed(_ error: Error) {
        guard let failure = error as? HandwritingRecognitionError, failure == .modelUnavailable else { return }
        Self.logger.error("model unusable, local copy dropped")
        session.setRecognizer(nil)
        session.reset()
        setStatus(.missing)
        Task { await ModelImporter.shared.discardLocalCopy() }
    }

    private func setStatus(_ status: ModelStatus) {
        guard status != modelStatus else { return }
        modelStatus = status
        onChange?()
    }
}
