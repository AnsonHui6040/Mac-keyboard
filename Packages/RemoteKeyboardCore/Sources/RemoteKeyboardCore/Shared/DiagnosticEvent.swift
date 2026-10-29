import OSLog

public enum DiagnosticKeyKind: String, Sendable {
    case text, backspace, `return`
}

public enum AckCode: String, Codable, Sendable {
    case posted, notAuthorized, noFocus, staleFocus, switchFailed, malformed
    /// An IME composition was still open after Escape; nothing was switched or injected.
    case compositionActive
}

/// Diagnostics carry state names, codes and sizes only. There is deliberately no free-text
/// payload, so typed text cannot reach the log. `receiverLink` takes a state name only.
public enum DiagnosticEvent: Equatable, Sendable {
    case keyboardLink(KeyboardLinkState)
    case receiverLink(String)
    case keySent(kind: DiagnosticKeyKind, utf8Length: Int)
    case ackReceived(AckCode)
    case reconnectSample(shownAtMs: Int64, connectedAtMs: Int64?)

    private static let logger = Logger(subsystem: "com.ansonhui.remotekeyboard", category: "diagnostic")

    public func log() {
        let logger = Self.logger
        switch self {
        case .keyboardLink(let state):
            logger.info("keyboardLink \(state.name, privacy: .public)")
        case .receiverLink(let name):
            logger.info("receiverLink \(Self.sanitizedStateName(name), privacy: .public)")
        case .keySent(let kind, let utf8Length):
            logger.info("keySent kind=\(kind.rawValue, privacy: .public) utf8Length=\(utf8Length, privacy: .public)")
        case .ackReceived(let code):
            logger.info("ack \(code.rawValue, privacy: .public)")
        case .reconnectSample(let shownAtMs, let connectedAtMs):
            logger.info("reconnect shownAtMs=\(shownAtMs, privacy: .public) connectedAtMs=\(connectedAtMs ?? -1, privacy: .public)")
        }
    }

    /// State names are short ASCII identifiers; anything else is not logged verbatim.
    static func sanitizedStateName(_ name: String) -> String {
        let isName = !name.isEmpty && name.count <= 24 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return isName ? name : "invalid"
    }
}
