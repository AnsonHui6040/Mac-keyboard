/// Quick (速成) as an input method: up to two letter keys make the code, the dictionary answers with candidates.
/// Space takes the first candidate. A Shift press (pressed again, it is cancelled) makes the next letter an uppercase English letter instead of a code.
public struct QuickInputMethod: ChineseInputMethod {
    public static let maxCodeLength = 2

    public let id = ChineseInputMethodID.quick
    private let dictionary: QuickDictionary
    private var code = ""
    private var shiftPending = false

    public init(dictionary: QuickDictionary) {
        self.dictionary = dictionary
    }

    public mutating func handle(_ input: IMEInput) -> IMEOutput {
        switch input {
        case .key(let text):
            return key(text)
        case .shift:
            shiftPending.toggle()
            return state()
        case .backspace:
            guard !code.isEmpty else { return IMEOutput(passThrough: .backspace, shift: shiftPending) }
            code.removeLast()
            return state()
        case .space:
            if let first = dictionary.candidates(for: code).first { return commit(first) }
            guard !code.isEmpty else { return IMEOutput(passThrough: .space, shift: shiftPending) }
            return clear()
        case .returnKey:
            return code.isEmpty ? IMEOutput(passThrough: .returnKey, shift: shiftPending) : clear()
        case .selectCandidate(let index):
            let list = dictionary.candidates(for: code)
            guard list.indices.contains(index) else { return state() }
            return commit(list[index])
        case .clear:
            return clear()
        case .recognized:
            return state()
        }
    }

    public mutating func reset() {
        code = ""
        shiftPending = false
    }

    private mutating func key(_ text: String) -> IMEOutput {
        guard text.utf8.count == 1, let byte = text.lowercased().utf8.first, byte >= 97, byte <= 122 else {
            return IMEOutput(passThrough: .character(text))
        }
        if shiftPending {
            shiftPending = false
            return IMEOutput(
                composing: CangjieRadicals.display(for: code), candidates: dictionary.candidates(for: code),
                passThrough: .character(text.uppercased()))
        }
        if code.count < Self.maxCodeLength { code += text.lowercased() }
        return state()
    }

    private func state() -> IMEOutput {
        IMEOutput(
            composing: CangjieRadicals.display(for: code), candidates: dictionary.candidates(for: code),
            shift: shiftPending)
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
