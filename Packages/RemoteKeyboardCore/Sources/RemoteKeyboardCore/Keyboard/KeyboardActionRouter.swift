/// The Local half of routing: typing goes straight into the host app's field. Mode, draft and readiness are decided
/// one level up, in `InputRouter`.
public struct KeyboardActionRouter {
    private let local: TextSink

    public init(local: TextSink) {
        self.local = local
    }

    public func type(_ key: TypedKey) -> RouteOutcome {
        switch key {
        case .text(let text): local.insertText(text)
        case .returnKey: local.insertText("\n")
        case .backspace: local.deleteBackward()
        }
        return .insertedLocally
    }
}
