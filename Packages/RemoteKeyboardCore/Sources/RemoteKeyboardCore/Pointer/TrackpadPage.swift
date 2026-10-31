import Foundation

/// Where the iPhone's touchpad channel stands.
public enum PointerChannelPhase: Equatable, Sendable {
    /// Not asked, or ended (page left, connection lost, grant changed).
    case closed
    /// `pointerOpen` sent, no answer yet.
    case opening
    /// The Mac said `posted`: `0x03` packets may be sent.
    case open
    /// The Mac refused, or took its grant away.
    case denied
    /// Two `pointerOpen` attempts went unanswered.
    case timedOut
}

/// What the touchpad page tells the user, and whether it takes touches.
public enum TrackpadAvailability: Equatable, Sendable {
    case offline, connecting, denied, failed, ready
}

public enum TrackpadPage {
    public static func availability(linkConnected: Bool, status: ReceiverStatus?, channel: PointerChannelPhase) -> TrackpadAvailability {
        guard linkConnected else { return .offline }
        switch channel {
        case .open: return .ready
        case .opening: return .connecting
        case .denied: return .denied
        case .timedOut: return .failed
        case .closed:
            // A status without a grant is a Mac whose switch is off (or an older Receiver): it will not open.
            guard let status else { return .connecting }
            return status.pointerGrant == nil ? .denied : .connecting
        }
    }

    /// The line drawn on the pad; `nil` when it is ready.
    public static func message(for availability: TrackpadAvailability) -> String? {
        switch availability {
        case .offline: StatusLine.pointerOfflineText
        case .connecting: StatusLine.pointerConnectingText
        case .denied: StatusLine.pointerDeniedText
        case .failed: StatusLine.pointerTimeoutText
        case .ready: nil
        }
    }
}
