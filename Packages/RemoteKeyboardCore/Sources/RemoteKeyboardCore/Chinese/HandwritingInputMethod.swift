/// Handwriting as an input method: the recognised candidates are the whole state. The ink itself lives in the writing
/// view; this type only knows whether there is any (`hasInk`), so the first delete, space or return after writing
/// clears the ink instead of acting on the text field.
public struct HandwritingInputMethod: ChineseInputMethod {
    public static let maxCandidates = 9

    public let id = ChineseInputMethodID.handwriting
    private var candidates: [String] = []
    private var hasInk = false

    public init() {}

    public mutating func handle(_ input: IMEInput) -> IMEOutput {
        switch input {
        case .recognized(let list):
            hasInk = true
            candidates = Array(HanCharacters.filter(list).prefix(Self.maxCandidates))
            return state()
        case .selectCandidate(let index):
            guard candidates.indices.contains(index) else { return state() }
            return commit(candidates[index])
        case .space:
            if let first = candidates.first { return commit(first) }
            return hasInk ? clear() : IMEOutput(passThrough: .space)
        case .backspace:
            return hasInk ? clear() : IMEOutput(passThrough: .backspace)
        case .returnKey:
            return hasInk ? clear() : IMEOutput(passThrough: .returnKey)
        case .clear:
            return clear()
        case .key(let text):
            return IMEOutput(passThrough: .character(text))
        case .shift:
            return IMEOutput()
        }
    }

    public mutating func reset() {
        candidates = []
        hasInk = false
    }

    private func state() -> IMEOutput {
        IMEOutput(candidates: candidates)
    }

    private mutating func commit(_ text: String) -> IMEOutput {
        reset()
        return IMEOutput(commit: text)
    }

    private mutating func clear() -> IMEOutput {
        reset()
        return IMEOutput()
    }
}
