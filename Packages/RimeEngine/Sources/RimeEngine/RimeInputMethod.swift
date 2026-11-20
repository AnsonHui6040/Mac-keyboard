import RemoteKeyboardCore

/// A keyed Chinese method backed by librime (Quick, Cangjie, Zhuyin, Pinyin, Jyutping). Only the scheme's keys reach
/// librime (letters lowercased), the code is capped at `RimeSchemeConfig.maxCodeLength`, and the one-shot Shift
/// lives here, not in librime.
public struct RimeInputMethod: ChineseInputMethod {
    public static let quickMaxCodeLength = RimeSchemeConfig.quick5.maxCodeLength

    public let id: ChineseInputMethodID
    private let session: RimeSession
    private let config: RimeSchemeConfig
    private var shiftPending = false

    public init(session: RimeSession, config: RimeSchemeConfig, id: ChineseInputMethodID) {
        self.session = session
        self.config = config
        self.id = id
    }

    public init(session: RimeSession, id: ChineseInputMethodID = .quick) {
        self.init(session: session, config: .quick5, id: id)
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
        let lowered = text.lowercased()
        guard lowered.count == 1, let key = lowered.first, config.keys.contains(key), let ascii = key.asciiValue else {
            return IMEOutput(passThrough: .character(text))
        }
        if shiftPending {
            shiftPending = false
            let current = session.state
            return IMEOutput(
                composing: composing(for: current.input), candidates: current.candidates,
                passThrough: .character(text.uppercased()))
        }
        if session.state.input.count < config.maxCodeLength { _ = session.processKey(Int32(ascii)) }
        return state()
    }

    private func state() -> IMEOutput {
        let current = session.state
        return IMEOutput(
            composing: composing(for: current.input), candidates: current.candidates, shift: shiftPending)
    }

    private func composing(for input: String) -> String {
        switch config.composing {
        case .cangjieRadicals:
            return CangjieRadicals.display(for: input)
        case .preedit:
            return session.preedit
        case .preeditWithKeyLabels(let labels):
            return session.preedit.map { labels[$0] ?? String($0) }.joined()
        }
    }

    /// Internal so tests can reach the failure path. If librime refuses the selection, or accepts it without
    /// committing yet (a sentence scheme where only the first part was chosen), the composition and the pending Shift
    /// are kept: the rest stays composing for the next selection.
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
