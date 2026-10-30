import CoreGraphics
import Foundation
import RemoteKeyboardCore
import os

/// Runs the handwriting input method for the keyboard: owns the pure `HandwritingInputMethod`, the ML Kit recognizer
/// and the model import, and turns "a stroke ended" into candidates. The controller feeds it keys and ink, and routes
/// what it commits through the `InputRouter`.
///
/// Memory: the recognizer is created when the Chinese page appears and dropped when the keyboard disappears (ML Kit
/// with the model loaded peaked at about 86 MB of the 177 MB limit in the O7 spike).
/// Privacy: ink, candidates and committed text are never logged; only counts, durations and status.
@MainActor
final class ChineseInputCoordinator {
    enum ModelStatus: Equatable {
        /// The Chinese page is not active.
        case idle
        /// Copying the model the host app put in the App Group.
        case importing
        case ready
        /// No model in the keyboard and none to import: the user has to download it in the app.
        case missing
    }

    /// Wait after a stroke ends before recognising, so a quick next stroke replaces the pending recognition.
    static let debounce = Duration.milliseconds(150)

    private(set) var candidates: [String] = []
    private(set) var modelStatus: ModelStatus = .idle
    /// Candidates or model status changed.
    var onChange: (() -> Void)?
    /// The writing view should drop its ink.
    var onClearInk: (() -> Void)?

    private let makeRecognizer: () -> (any HandwritingRecognizing)?
    private var method = HandwritingInputMethod()
    private var recognizer: (any HandwritingRecognizing)?
    private var recognition: Task<Void, Never>?
    private var importing: Task<Void, Never>?
    /// Bumped by every change of the ink, so a late recognition result for older ink is dropped.
    private var generation = 0
    private static let logger = Logger(subsystem: "com.ansonhui.remotekeyboard", category: "handwriting")

    init(makeRecognizer: @escaping () -> (any HandwritingRecognizing)? = { MLKitRecognizer() }) {
        self.makeRecognizer = makeRecognizer
    }

    // MARK: Lifecycle

    /// The Chinese page is on screen. Loads the recognizer, importing the model from the App Group first if needed.
    func activate() {
        guard recognizer == nil, importing == nil else { return }
        if MLKitHandwriting.isModelDownloaded() {
            becomeReady()
            return
        }
        setStatus(.importing)
        importing = Task { [weak self] in
            let started = ContinuousClock.now
            let imported = await Task.detached(priority: .userInitiated) {
                (try? HandwritingModelStore.importFromGroup()) != nil
            }.value
            guard let self, !Task.isCancelled else { return }
            self.importing = nil
            let elapsed = started.duration(to: .now)
            Self.logger.info("model import finished ok=\(imported, privacy: .public) seconds=\(elapsed.components.seconds, privacy: .public)")
            if imported, MLKitHandwriting.isModelDownloaded() {
                self.becomeReady()
            } else {
                self.setStatus(.missing)
            }
        }
    }

    /// The keyboard disappeared: free the recognizer and forget the composition.
    func deactivate() {
        recognition?.cancel()
        importing?.cancel()
        recognition = nil
        importing = nil
        recognizer = nil
        resetComposition()
        setStatus(.idle)
    }

    /// Drops ink and candidates (the user left the Chinese page).
    func resetComposition() {
        recognition?.cancel()
        recognition = nil
        generation &+= 1
        method.reset()
        let changed = !candidates.isEmpty
        candidates = []
        onClearInk?()
        if changed { onChange?() }
    }

    // MARK: Ink

    /// A new stroke started: a pending recognition is for older ink.
    func strokeBegan() {
        recognition?.cancel()
        recognition = nil
        generation &+= 1
    }

    /// A stroke ended; `strokes` is all the ink on the writing area. Recognises it once the user pauses.
    func strokesEnded(_ strokes: [[CGPoint]], size: CGSize) {
        generation &+= 1
        let current = generation
        recognition?.cancel()
        recognition = nil
        // The method learns that there is ink at once, so delete, space and return clear it instead of the text field.
        _ = method.handle(.recognized(candidates))
        guard !strokes.isEmpty, let recognizer, modelStatus == .ready else { return }
        recognition = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            var list: [String] = []
            do {
                list = try await recognizer.recognize(strokes: strokes, in: size)
            } catch {
                // The error code is logged by the recognizer. No candidates for this ink.
            }
            guard !Task.isCancelled, let self, self.generation == current else { return }
            self.recognition = nil
            self.apply(self.method.handle(.recognized(list)))
        }
    }

    // MARK: Keys

    /// Feeds one input to the method and returns its answer. A candidate list that comes back empty also clears the
    /// writing view (commit, clear, or a key that consumed the ink).
    func handle(_ input: IMEInput) -> IMEOutput {
        recognition?.cancel()
        recognition = nil
        generation &+= 1
        let output = method.handle(input)
        apply(output)
        onClearInk?()
        return output
    }

    // MARK: Private

    private func becomeReady() {
        guard let made = makeRecognizer() else {
            setStatus(.missing)
            return
        }
        recognizer = made
        setStatus(.ready)
    }

    private func apply(_ output: IMEOutput) {
        guard output.candidates != candidates else { return }
        candidates = output.candidates
        onChange?()
    }

    private func setStatus(_ status: ModelStatus) {
        guard status != modelStatus else { return }
        modelStatus = status
        onChange?()
    }
}
