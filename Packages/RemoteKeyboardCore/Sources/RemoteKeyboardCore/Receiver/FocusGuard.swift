import Foundation

/// What the Receiver knows about the Mac's keyboard focus at one instant.
public struct FocusSnapshot: Equatable, Sendable {
    public let axTrusted: Bool
    public let frontmostPID: Int32
    public let appName: String?
    public let editable: Bool
    /// Bumps whenever the frontmost app or the focused UI element changes.
    public let epoch: UInt64

    public init(axTrusted: Bool, frontmostPID: Int32, appName: String?, editable: Bool, epoch: UInt64) {
        self.axTrusted = axTrusted
        self.frontmostPID = frontmostPID
        self.appName = appName
        self.editable = editable
        self.epoch = epoch
    }
}

public enum InjectionDecision: Equatable, Sendable {
    case allow, notAuthorized, noFocus, staleFocus
}

/// Pure gate in front of every injection. Fails closed: anything unknown refuses.
public enum FocusGuard {
    /// - Parameter eventEpoch: the focus epoch the event was typed against, or `nil` when there is none to compare.
    public static func authorize(eventEpoch: UInt64?, current: FocusSnapshot?) -> InjectionDecision {
        guard let current, current.axTrusted else { return .notAuthorized }
        guard current.editable else { return .noFocus }
        if let eventEpoch, eventEpoch != current.epoch { return .staleFocus }
        return .allow
    }
}
