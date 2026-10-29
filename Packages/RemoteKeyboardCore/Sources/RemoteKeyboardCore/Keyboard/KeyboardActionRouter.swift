public struct KeyboardActionRouter {
    private let local: TextSink
    private let remote: RemoteEventSink
    private let isRemoteReady: () -> Bool

    public init(local: TextSink, remote: RemoteEventSink, isRemoteReady: @escaping () -> Bool) {
        self.local = local
        self.remote = remote
        self.isRemoteReady = isRemoteReady
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

        switch mode {
        case .local:
            routeLocal(action)
            return .insertedLocally
        case .remote:
            // A key that cannot reach the Mac is refused, never typed into the host app instead.
            guard isRemoteReady() else { return .rejected }
            remote.enqueue(Self.eventKind(for: action))
            return .enqueuedRemote
        }
    }

    private func routeLocal(_ action: KeyAction) {
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
    }

    private static func eventKind(for action: KeyAction) -> EventKind {
        switch action {
        case .character(let text): .text(text)
        case .space: .text(" ")
        case .returnKey: .returnKey
        case .backspace: .backspace
        case .nextKeyboard, .toggleMode: preconditionFailure("handled before remote routing")
        }
    }
}
