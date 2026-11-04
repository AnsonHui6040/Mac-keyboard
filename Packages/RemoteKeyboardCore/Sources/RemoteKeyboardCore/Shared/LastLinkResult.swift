import Foundation

/// How the keyboard's last attempt to reach the Mac ended. The Extension stores it in the App Group (`rawValue`) and the
/// host App reads it for the setup checklist. It holds no text and nothing about the Mac.
public enum LastLinkResult: String, Equatable, Sendable {
    /// The link came up and the handshake passed.
    case connected
    /// The Mac answered but the pair key did not prove out.
    case authFailed
    /// A paired keyboard sat in Remote mode for a while and never got a link.
    case unreachable

    /// A problem older than this says nothing about today's link.
    public static let problemLifetimeSeconds: Double = 86_400

    /// What the stored values mean at `now`: a problem expires, a connected result does not.
    public static func current(raw: String?, recordedAt: Double?, now: Double) -> LastLinkResult? {
        guard let result = raw.flatMap(LastLinkResult.init(rawValue:)) else { return nil }
        if result == .connected { return result }
        guard let recordedAt, now - recordedAt < problemLifetimeSeconds else { return nil }
        return result
    }
}

/// Decides what the Extension records for one keyboard appearance. The caller feeds what it saw and writes whatever
/// comes back; `nil` means leave the earlier result alone.
public struct LinkResultRecorder: Equatable, Sendable {
    /// A shorter appearance says nothing about the link: the keyboard was just passing by.
    public static let minimumOnScreenMs: Int64 = 10_000

    private var appearedAtMs: Int64?
    private var sawRemote = false
    private var connected = false
    private var authFailed = false

    public init() {}

    /// The keyboard came on screen. A repeat inside one appearance keeps the first start.
    public mutating func appeared(atMs: Int64, remote: Bool) {
        if appearedAtMs == nil { appearedAtMs = atMs }
        if remote { sawRemote = true }
    }

    /// The effective mode changed while on screen.
    public mutating func modeChanged(remote: Bool) {
        if remote { sawRemote = true }
    }

    /// The link is connected and the handshake passed.
    public mutating func linkAuthenticated() -> LastLinkResult? {
        connected = true
        authFailed = false
        return .connected
    }

    /// The handshake failed.
    public mutating func authenticationFailed() -> LastLinkResult? {
        authFailed = true
        return .authFailed
    }

    /// The keyboard went away; this ends the appearance.
    public mutating func disappeared(atMs: Int64, paired: Bool) -> LastLinkResult? {
        defer { self = LinkResultRecorder() }
        guard let start = appearedAtMs, sawRemote, paired, !connected, !authFailed,
              atMs - start >= Self.minimumOnScreenMs else { return nil }
        return .unreachable
    }
}
