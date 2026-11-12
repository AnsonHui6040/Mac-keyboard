/// Decides where a key goes: the host app's field (Local), the draft, or the Mac (Remote).
///
/// In Remote mode a typing key edits the draft when the draft already has text or when the user chose the draft;
/// otherwise it is sent at once when the Mac is ready and dropped when it is not. While the Mac is blocked (a password
/// field) text and return are dropped whatever the mode, so a password never sits in the draft. Cursor keys only ever
/// move the draft cursor.
public struct InputRouter {
    private let local: KeyboardActionRouter
    private let remote: RemoteEventSink

    public init(local: TextSink, remote: RemoteEventSink) {
        self.local = KeyboardActionRouter(local: local)
        self.remote = remote
    }

    public func route(
        _ action: KeyAction, mode: KeyboardMode, transmit: TransmitMode, ready: Bool, draft: inout DraftBuffer,
        blocked: Bool = false
    ) -> RouteOutcome {
        switch action {
        case .toggleMode:
            return .modeToggled(mode == .local ? .remote : .local)
        case .toggleTransmit:
            return .transmitToggled(transmit.toggled)
        case .nextKeyboard:
            return .advanceInputMode
        case .dismissKeyboard:
            return .dismissKeyboard
        case .cycleHost:
            return .cycleHost
        case .switchChineseEnglish, .switchSymbols:
            return .pageChanged
        case .cursorLeft:
            guard mode == .remote else { return .rejected }
            draft.moveLeft()
            return .draftEdited
        case .cursorRight:
            guard mode == .remote else { return .rejected }
            draft.moveRight()
            return .draftEdited
        case .setDraftCursor(let index):
            guard mode == .remote else { return .rejected }
            draft.moveCursor(to: index)
            return .draftEdited
        case .sendDraft:
            guard mode == .remote, ready, !draft.isEmpty else { return .rejected }
            let events = draft.takeEvents()
            for event in events { remote.enqueue(event) }
            return .draftSent(events.count)
        case .character(let text):
            return type(.text(text), mode: mode, transmit: transmit, ready: ready, blocked: blocked, draft: &draft)
        case .space:
            return type(.text(" "), mode: mode, transmit: transmit, ready: ready, blocked: blocked, draft: &draft)
        case .returnKey:
            return type(.returnKey, mode: mode, transmit: transmit, ready: ready, blocked: blocked, draft: &draft)
        case .backspace:
            return type(.backspace, mode: mode, transmit: transmit, ready: ready, blocked: blocked, draft: &draft)
        }
    }

    /// Remote order: blocked keeps text out of the draft altogether (backspace may still trim what is there); then the
    /// draft takes the key when it is chosen or already has text; otherwise the key goes to the Mac if it is ready, and
    /// is dropped (`.rejected`, nothing stored) if not.
    private func type(
        _ key: TypedKey, mode: KeyboardMode, transmit: TransmitMode, ready: Bool, blocked: Bool, draft: inout DraftBuffer
    ) -> RouteOutcome {
        guard mode == .remote else { return local.type(key) }
        if blocked {
            guard case .backspace = key, !draft.isEmpty else { return .rejected }
        } else if transmit != .draft, draft.isEmpty {
            guard ready else { return .rejected }
            remote.enqueue(key.eventKind)
            return .enqueuedRemote
        }
        switch key {
        case .text(let text): return draft.insert(text) ? .draftEdited : .draftFull
        case .returnKey: return draft.insert("\n") ? .draftEdited : .draftFull
        case .backspace:
            draft.deleteBackward()
            return .draftEdited
        }
    }
}
