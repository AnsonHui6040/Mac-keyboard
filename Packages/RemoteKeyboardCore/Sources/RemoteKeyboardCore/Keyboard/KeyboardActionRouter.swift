public struct KeyboardActionRouter {
    private let local: TextSink
    private let remote: RemoteEventSink

    public init(local: TextSink, remote: RemoteEventSink) {
        self.local = local
        self.remote = remote
    }

    public func route(_ action: KeyAction, mode: KeyboardMode) -> RouteOutcome {
        switch action {
        case .toggleMode:
            return .modeToggled(mode == .local ? .remote : .local)
        case .nextKeyboard:
            return .advanceInputMode
        default:
            break
        }

        // Remote routing arrives in T05; until then every other action is refused.
        guard mode == .local else { return .rejected }

        switch action {
        case .character(let text):
            local.insertText(text)
        case .space:
            local.insertText(" ")
        case .returnKey:
            local.insertText("\n")
        case .backspace:
            local.deleteBackward()
        case .nextKeyboard, .toggleMode:
            break
        }
        return .insertedLocally
    }
}
