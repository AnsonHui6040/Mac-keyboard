import OSLog

public enum DiagnosticKeyKind: String, Sendable {
    case text, backspace, `return`
}

public enum AckCode: String, Codable, Sendable {
    case posted, notAuthorized, noFocus, staleFocus, switchFailed, malformed
    /// An IME composition was still open after Escape; nothing was switched or injected.
    case compositionActive
    /// The Receiver tried to type the event and a posting step failed.
    case injectFailed
    /// The answer to a latency probe, which is never typed.
    case pong
    /// The event's `seq` was not above the highest one already processed in its session; nothing was typed.
    case outOfOrder
}

/// Why a key was not sent. Fixed names only.
public enum KeyDropReason: String, Sendable {
    case tooLarge, encodeFailed
}

/// Diagnostics carry state names, codes and sizes only. There is deliberately no free-text
/// payload, so typed text cannot reach the log. `receiverLink` takes a state name only.
public enum DiagnosticEvent: Equatable, Sendable {
    case keyboardLink(KeyboardLinkState)
    case receiverLink(String)
    case keySent(kind: DiagnosticKeyKind, utf8Length: Int)
    case ackReceived(AckCode)
    /// A key that could not be encoded for the subscribed central; kind and length only.
    case keyDropped(kind: DiagnosticKeyKind, utf8Length: Int, reason: KeyDropReason)
    /// The subscribed central's `maximumUpdateValueLength`, logged once per subscription.
    case centralSubscribed(maxUpdateLength: Int)
    case reconnectSample(shownAtMs: Int64, connectedAtMs: Int64?)
    /// The link dropped with this many keys never acknowledged. A count only.
    case keysUnconfirmed(count: Int)

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
        case .keyDropped(let kind, let utf8Length, let reason):
            logger.error("keyDropped kind=\(kind.rawValue, privacy: .public) utf8Length=\(utf8Length, privacy: .public) reason=\(reason.rawValue, privacy: .public)")
        case .centralSubscribed(let maxUpdateLength):
            logger.info("centralSubscribed maxUpdateLength=\(maxUpdateLength, privacy: .public)")
        case .reconnectSample(let shownAtMs, let connectedAtMs):
            logger.info("reconnect shownAtMs=\(shownAtMs, privacy: .public) connectedAtMs=\(connectedAtMs ?? -1, privacy: .public)")
        case .keysUnconfirmed(let count):
            logger.info("keysUnconfirmed count=\(count, privacy: .public)")
        }
    }

    /// State names are short ASCII identifiers; anything else is not logged verbatim.
    static func sanitizedStateName(_ name: String) -> String {
        let isName = !name.isEmpty && name.count <= 24 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return isName ? name : "invalid"
    }
}
