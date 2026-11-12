/// Whether keys go to the Mac at once or are collected in the draft first. Persisted as `rk.transmit`.
public enum TransmitMode: String, Codable, Sendable {
    case instant
    case draft

    var toggled: TransmitMode { self == .instant ? .draft : .instant }

    /// Decodes the persisted raw value; anything missing or unknown is instant.
    public static func stored(rawValue: String?) -> TransmitMode {
        rawValue.flatMap(TransmitMode.init(rawValue:)) ?? .instant
    }
}

/// What one key press means, independent of the key layout that produced it.
public enum KeyAction: Equatable, Sendable {
    case character(String)
    case backspace
    case space
    case returnKey
    case cursorLeft
    case cursorRight
    /// A tap or drag on the draft put the cursor before the Character at this index (clamped by the draft).
    case setDraftCursor(Int)
    case sendDraft
    case toggleMode
    case toggleTransmit
    case nextKeyboard
    case switchChineseEnglish
    case switchSymbols
    /// Hides the keyboard. Touches neither the text nor the draft.
    case dismissKeyboard
    /// The status cell was tapped while two or more hosts are paired: the keyboard types to the next host in the list.
    /// Touches neither the text nor the draft.
    case cycleHost
}

/// The keys that put text into something (the host field, the draft or the Mac). Everything else in `KeyAction` only
/// changes keyboard state.
public enum TypedKey: Equatable, Sendable {
    case text(String)
    case backspace
    case returnKey

    public var eventKind: EventKind {
        switch self {
        case .text(let text): .text(text)
        case .backspace: .backspace
        case .returnKey: .returnKey
        }
    }
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
    /// The dismiss key was pressed; the controller hides the keyboard.
    case dismissKeyboard
    /// The status cell was tapped; the controller moves to the next host (it does nothing with fewer than two).
    case cycleHost
    case modeToggled(KeyboardMode)
    case transmitToggled(TransmitMode)
    /// A page key was pressed; the controller applies it to its `PageNavigator`.
    case pageChanged
    case draftEdited
    /// The draft was sent; the count is every event produced from it.
    case draftSent(Int)
    /// An insert into the draft was refused at the character cap; the draft is unchanged.
    case draftFull
    /// The key had no effect: sending an empty or not-ready draft, or a draft key pressed in Local mode.
    case rejected
}
