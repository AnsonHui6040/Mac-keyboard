/// Decides where a key goes: the host app's field (Local), the draft, or the Mac (Remote).
///
/// In Remote mode a typing key edits the draft when the draft already has text, when the user chose the draft, or
/// when the Mac is not ready; otherwise it is sent at once. Cursor keys only ever move the draft cursor.
public struct InputRouter {
    private let local: KeyboardActionRouter
    private let remote: RemoteEventSink

    public init(local: TextSink, remote: RemoteEventSink) {
        self.local = KeyboardActionRouter(local: local)
        self.remote = remote
    }

    public func route(
        _ action: KeyAction, mode: KeyboardMode, transmit: TransmitMode, ready: Bool, draft: inout DraftBuffer
    ) -> RouteOutcome {
        switch action {
        case .toggleMode:
            return .modeToggled(mode == .local ? .remote : .local)
        case .toggleTransmit:
            return .transmitToggled(transmit.toggled)
        case .nextKeyboard:
            return .advanceInputMode
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
        case .sendDraft:
            guard mode == .remote, ready, !draft.isEmpty else { return .rejected }
            let events = draft.takeEvents()
            for event in events { remote.enqueue(event) }
            return .draftSent(events.count)
        case .character(let text):
            return type(.text(text), mode: mode, transmit: transmit, ready: ready, draft: &draft)
        case .space:
            return type(.text(" "), mode: mode, transmit: transmit, ready: ready, draft: &draft)
        case .returnKey:
            return type(.returnKey, mode: mode, transmit: transmit, ready: ready, draft: &draft)
        case .backspace:
            return type(.backspace, mode: mode, transmit: transmit, ready: ready, draft: &draft)
        }
    }

    private func type(
        _ key: TypedKey, mode: KeyboardMode, transmit: TransmitMode, ready: Bool, draft: inout DraftBuffer
    ) -> RouteOutcome {
        guard mode == .remote else { return local.type(key) }
        guard transmit == .draft || !draft.isEmpty || !ready else {
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
