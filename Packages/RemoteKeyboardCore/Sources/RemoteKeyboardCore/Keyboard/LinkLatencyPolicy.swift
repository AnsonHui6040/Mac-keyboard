import Foundation

/// Which BLE connection interval the keyboard asks the Mac for. An open pointer needs the fastest one; typing within the
/// last `idleAfterMs` the default one; an idle link the slowest, which spares bluetoothd on both devices. Time is injected,
/// never read. Incoming status messages and the pointer's own packets are not activity: an open pointer is `.low` anyway.
public struct LinkLatencyPolicy: Equatable, Sendable {
    public enum Level: Equatable, Sendable {
        case low, medium, high
    }

    public static let idleAfterMs: Int64 = 10_000

    private var lastActivityMs: Int64?
    private var pointerOpen = false

    public init() {}

    /// An outgoing key or text event, the pointer opening, or a new link.
    public mutating func noteActivity(atMs: Int64) {
        lastActivityMs = atMs
    }

    public mutating func setPointerOpen(_ open: Bool) {
        pointerOpen = open
    }

    public func desired(atMs: Int64) -> Level {
        if pointerOpen { return .low }
        return isRecent(atMs: atMs) ? .medium : .high
    }

    /// When `desired` changes by itself, so the caller can arm one one-shot timer. `nil`: it only changes on input.
    public func nextChangeAtMs(atMs: Int64) -> Int64? {
        guard !pointerOpen, isRecent(atMs: atMs), let lastActivityMs else { return nil }
        return lastActivityMs + Self.idleAfterMs
    }

    private func isRecent(atMs: Int64) -> Bool {
        guard let lastActivityMs else { return false }
        return atMs - lastActivityMs < Self.idleAfterMs
    }
}
