public enum EventKind: Equatable, Sendable {
    case text(String)
    case backspace
    case returnKey
}

public enum KeyAction: Equatable, Sendable {
    case character(String)
    case backspace
    case space
    case returnKey
    case nextKeyboard
    case toggleMode
}

public protocol TextSink {
    func insertText(_ text: String)
    func deleteBackward()
}

public protocol RemoteEventSink {
    func enqueue(_ kind: EventKind)
}

public enum RouteOutcome: Equatable {
    case insertedLocally
    case enqueuedRemote
    case advanceInputMode
    case modeToggled(KeyboardMode)
    case rejected
}
