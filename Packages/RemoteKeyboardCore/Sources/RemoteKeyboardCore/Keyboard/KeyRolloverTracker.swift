/// Fast typing: a second key goes down while the first is still held. The first key is sent at once instead of at
/// its release, so characters leave in the order the keys went down. Pure bookkeeping; the view sends the keys.
///
/// Keys are identified by an `Int` the view assigns. Only keys that fire on release take part (letters and symbols);
/// repeating keys (delete), Shift and the other function keys do not.
public struct KeyRolloverTracker: Sendable {
    /// Keys that are down and have not been sent yet, in press order.
    private var pending: [Int] = []

    public init() {}

    /// A key went down. Returns the other keys still waiting, in press order: send them now, before this key.
    public mutating func touchDown(_ key: Int) -> [Int] {
        let flush = pending.filter { $0 != key }
        pending = [key]
        return flush
    }

    /// A key was released inside. True when it must be sent now; false when it was already sent by a later key's
    /// touch down (or was never down).
    public mutating func touchUpInside(_ key: Int) -> Bool {
        guard let index = pending.firstIndex(of: key) else { return false }
        pending.remove(at: index)
        return true
    }

    /// The touch ended without a tap (released outside, or cancelled): the key is never sent.
    public mutating func cancel(_ key: Int) {
        pending.removeAll { $0 == key }
    }

    /// Forgets every waiting key (the keyboard went away).
    public mutating func reset() {
        pending = []
    }
}
