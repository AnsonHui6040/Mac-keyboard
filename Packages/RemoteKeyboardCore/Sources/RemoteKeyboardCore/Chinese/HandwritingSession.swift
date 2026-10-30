import CoreGraphics

/// Turns strokes into candidates for the handwriting page and applies the keys to them. Owns the pure
/// `HandwritingInputMethod`, the debounce, and the rule that a space or return pressed while a recognition is still
/// pending first recognises the current ink, so older candidates are never committed and a one-stroke character is
/// not lost. The keyboard supplies the recognizer (nil while the model is not ready).
///
/// The history of committed characters (at most 20) is passed to the recognizer as context. It lives in memory only,
/// is never logged, and is cleared by `resetHistory()` / `deactivate()`.
@MainActor
public final class HandwritingSession {
    /// Wait after a stroke ends before recognising, so a quick next stroke replaces the pending recognition.
    public static let debounce = Duration.milliseconds(150)
    public static let preContextLength = 20
    /// Longest a space or return waits for a recognition; then it uses the candidates it has.
    public static let defaultWaitTimeout = Duration.seconds(1)

    public private(set) var candidates: [String] = []
    /// Candidates changed.
    public var onChange: (() -> Void)?
    /// The writing view should drop its ink.
    public var onClearInk: (() -> Void)?
    /// The recognizer threw; the session keeps going with no candidates for that ink.
    public var onRecognizerError: ((Error) -> Void)?

    private let sleep: @MainActor @Sendable (Duration) async throws -> Void
    private let waitTimeout: Duration
    private var recognizer: (any HandwritingRecognizing)?
    private var method = HandwritingInputMethod()
    private var ink: [[InkPoint]] = []
    private var size = CGSize.zero
    /// The ink changed and its recognition has not been applied yet.
    private var needsRecognition = false
    /// Bumped by every change of the ink, so a late result for older ink is dropped.
    private var generation = 0
    private var scheduled: Task<Void, Never>?
    private var history = ""

    public init(
        sleep: @escaping @MainActor @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        waitTimeout: Duration = HandwritingSession.defaultWaitTimeout
    ) {
        self.sleep = sleep
        self.waitTimeout = waitTimeout
    }

    public var hasRecognizer: Bool { recognizer != nil }

    /// True when a delete press is taken by the session (it clears ink or candidates) instead of editing the text.
    public var consumesBackspace: Bool { needsRecognition || !ink.isEmpty || !candidates.isEmpty }

    /// Sets the engine (nil while the model is not ready). Ink written before it arrived is recognised now.
    public func setRecognizer(_ recognizer: (any HandwritingRecognizing)?) {
        self.recognizer = recognizer
        if recognizer != nil, needsRecognition, scheduled == nil { scheduleRecognition() }
    }

    // MARK: Ink

    /// A new stroke started: a pending recognition is for older ink.
    public func strokeBegan() {
        scheduled?.cancel()
        scheduled = nil
        generation &+= 1
    }

    /// A stroke ended; `strokes` is all the ink on the writing area. Recognises it once the user pauses.
    public func strokesEnded(_ strokes: [[InkPoint]], size: CGSize) {
        scheduled?.cancel()
        generation &+= 1
        ink = strokes
        self.size = size
        needsRecognition = !strokes.isEmpty
        // The method learns that there is ink at once, so delete, space and return clear it instead of the text field.
        _ = method.handle(.recognized(candidates))
        guard needsRecognition, recognizer != nil else { return }
        scheduleRecognition()
    }

    // MARK: Keys

    /// Feeds one input to the method and returns its answer. Space and return wait for a pending recognition first, for
    /// at most `waitTimeout`; after that they use the candidates already there. A new stroke that starts during the
    /// wait cancels the key.
    public func handle(_ input: IMEInput) async -> IMEOutput {
        if (input == .space || input == .returnKey), needsRecognition, recognizer != nil {
            scheduled?.cancel()
            scheduled = nil
            let current = generation
            let result = await recognizeWithDeadline(generation: current)
            guard generation == current else { return IMEOutput(candidates: candidates) }
            if case .finished(let list) = result { applyRecognized(list ?? []) }
        }
        scheduled?.cancel()
        scheduled = nil
        generation &+= 1
        needsRecognition = false
        ink = []
        let output = method.handle(input)
        if let text = output.commit {
            history = String((history + text).suffix(Self.preContextLength))
        } else if output.passThrough == .backspace {
            // A delete that reaches the text removes the last committed character too.
            history = String(history.dropLast())
        }
        setCandidates(output.candidates)
        onClearInk?()
        return output
    }

    // MARK: Lifecycle

    /// Drops ink and candidates (the user left the Chinese page).
    public func reset() {
        scheduled?.cancel()
        scheduled = nil
        generation &+= 1
        needsRecognition = false
        ink = []
        method.reset()
        setCandidates([])
        onClearInk?()
    }

    /// Forgets what was committed (mode switch).
    public func resetHistory() {
        history = ""
    }

    /// The keyboard disappeared: drop everything, including the recognizer.
    public func deactivate() {
        reset()
        resetHistory()
        recognizer = nil
    }

    // MARK: Private

    private func scheduleRecognition() {
        let current = generation
        scheduled = Task { [weak self] in
            guard let self else { return }
            try? await self.sleep(Self.debounce)
            guard !Task.isCancelled else { return }
            let list = await self.recognizeCurrent(generation: current)
            guard !Task.isCancelled, let list else { return }
            self.applyRecognized(list)
        }
    }

    private enum WaitResult {
        case finished([String]?)
        case timedOut
    }

    /// Resolved by whichever of the recognition and the timer comes first.
    @MainActor
    private final class Gate {
        var done = false
    }

    /// `recognizeCurrent` raced against `waitTimeout`. On a timeout the recognition keeps running; its late result is
    /// dropped because the ink generation has moved on.
    private func recognizeWithDeadline(generation current: Int) async -> WaitResult {
        let gate = Gate()
        let timeout = waitTimeout
        return await withCheckedContinuation { (continuation: CheckedContinuation<WaitResult, Never>) in
            let timer = Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, !gate.done else { return }
                gate.done = true
                continuation.resume(returning: .timedOut)
            }
            Task { @MainActor [weak self] in
                let list = await self?.recognizeCurrent(generation: current)
                guard !gate.done else { return }
                gate.done = true
                timer.cancel()
                continuation.resume(returning: .finished(list))
            }
        }
    }

    /// Recognises the current ink; nil when there is nothing to recognise or the ink changed meanwhile.
    private func recognizeCurrent(generation current: Int) async -> [String]? {
        guard let recognizer, !ink.isEmpty else { return nil }
        let strokes = ink
        let area = size
        var list: [String] = []
        do {
            list = try await recognizer.recognize(strokes: strokes, in: area, preContext: history)
        } catch {
            onRecognizerError?(error)
        }
        return generation == current ? list : nil
    }

    private func applyRecognized(_ list: [String]) {
        needsRecognition = false
        setCandidates(method.handle(.recognized(list)).candidates)
    }

    private func setCandidates(_ list: [String]) {
        guard list != candidates else { return }
        candidates = list
        onChange?()
    }

    #if DEBUG
    /// Tests only: waits for the scheduled recognition.
    func settle() async {
        await scheduled?.value
    }
    #endif
}
