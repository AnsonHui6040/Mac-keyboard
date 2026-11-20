import RemoteKeyboardCore

/// Quick (速成) backed by librime. Behaves like `QuickInputMethod`: only single ASCII letters reach librime
/// (lowercased), at most two codes are kept, and the one-shot Shift lives here, not in librime.
public struct RimeInputMethod: ChineseInputMethod {
    public static let quickMaxCodeLength = 2

    public let id: ChineseInputMethodID
    private let session: RimeSession
    private var shiftPending = false

    public init(session: RimeSession, id: ChineseInputMethodID = .quick) {
        self.session = session
        self.id = id
    }

    public mutating func handle(_ input: IMEInput) -> IMEOutput {
        switch input {
        case .key(let text):
            return key(text)
        case .shift:
            shiftPending.toggle()
            return state()
        case .backspace:
            guard !session.state.input.isEmpty else {
                return IMEOutput(passThrough: .backspace, shift: shiftPending)
            }
            _ = session.processKey(RimeKeyCode.backSpace)
            return state()
        case .space:
            let current = session.state
            if !current.candidates.isEmpty { return commit(index: 0) }
            guard !current.input.isEmpty else { return IMEOutput(passThrough: .space, shift: shiftPending) }
            return clear()
        case .returnKey:
            return session.state.input.isEmpty ? IMEOutput(passThrough: .returnKey, shift: shiftPending) : clear()
        case .selectCandidate(let index):
            guard session.state.candidates.indices.contains(index) else { return state() }
            return commit(index: index)
        case .clear:
            return clear()
        case .recognized:
            return state()
        }
    }

    public mutating func reset() {
        session.clear()
        shiftPending = false
    }

    private mutating func key(_ text: String) -> IMEOutput {
        guard text.utf8.count == 1, let byte = text.lowercased().utf8.first, byte >= 97, byte <= 122 else {
            return IMEOutput(passThrough: .character(text))
        }
        if shiftPending {
            shiftPending = false
            let current = session.state
            return IMEOutput(
                composing: CangjieRadicals.display(for: current.input), candidates: current.candidates,
                passThrough: .character(text.uppercased()))
        }
        if session.state.input.count < Self.quickMaxCodeLength { _ = session.processKey(Int32(byte)) }
        return state()
    }

    private func state() -> IMEOutput {
        let current = session.state
        return IMEOutput(
            composing: CangjieRadicals.display(for: current.input), candidates: current.candidates,
            shift: shiftPending)
    }

    /// Internal so tests can reach the failure path. If librime refuses the selection, the composition and the
    /// pending Shift are kept so the user can retry or clear.
    mutating func commit(index: Int) -> IMEOutput {
        _ = session.takeCommit()  // drop any stale commit left by an earlier key
        guard session.selectCandidate(index), let committed = session.takeCommit() else { return state() }
        reset()
        return IMEOutput(commit: committed)
    }

    private mutating func clear() -> IMEOutput {
        reset()
        return IMEOutput()
    }
}
