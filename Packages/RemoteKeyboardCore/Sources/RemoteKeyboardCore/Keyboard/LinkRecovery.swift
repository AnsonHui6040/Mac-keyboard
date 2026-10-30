/// When the keyboard publishes its service again because a "connected" link cannot work.
///
/// After the Mac drops a connection for an authentication failure (it says nothing sealed, correctly), iOS may keep the
/// link and the keyboard stays `.connected` with a handshake that can never succeed. The liveness probe needs an
/// authenticated handshake, so this covers the failed one. A handshake still in progress is never reset.
///
/// A keyboard that holds no pair key is left alone: its handshake fails on every connection by itself, so a reset would
/// only make the Mac reconnect and fail again. The status line already tells that user to pair.
public enum LinkRecovery {
    /// A keyboard appears on a link that is connected but whose handshake already failed.
    public static func shouldResetOnAppear(
        linkConnected: Bool, handshake: PhoneHandshake.Progress?, hasPairKey: Bool
    ) -> Bool {
        linkConnected && handshake == .failed && hasPairKey
    }

    /// The handshake has just failed on this connection (the Mac sent `authFailed`, or the proof did not verify).
    public static func shouldResetAfterHandshakeFailure(hasPairKey: Bool) -> Bool {
        hasPairKey
    }
}
