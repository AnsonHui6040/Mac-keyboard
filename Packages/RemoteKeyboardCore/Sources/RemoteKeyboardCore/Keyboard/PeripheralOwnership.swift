/// Decides which keyboard view controller currently owns the process-wide peripheral.
///
/// The system may create a new controller before the old one disappears, or keep an old one alive. Only the latest
/// claimant may tear the link down, so a late `viewDidDisappear` of a stale controller is ignored.
public struct PeripheralOwnership<Owner: Hashable & Sendable>: Sendable {
    public private(set) var owner: Owner?

    public init() {}

    public func isOwner(_ candidate: Owner) -> Bool { owner == candidate }

    /// Makes `candidate` the owner. Returns true when that changed who owns it.
    @discardableResult
    public mutating func claim(_ candidate: Owner) -> Bool {
        guard owner != candidate else { return false }
        owner = candidate
        return true
    }

    /// Clears ownership only when `candidate` is the owner. Returns whether it was, so the caller knows whether the
    /// disappear (or deinit) is honored.
    @discardableResult
    public mutating func release(_ candidate: Owner) -> Bool {
        guard owner == candidate else { return false }
        owner = nil
        return true
    }
}
