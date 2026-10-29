import Foundation

/// FIFO of encoded frames waiting for the BLE transmit queue. Order is never changed.
public struct NotifyQueue: Sendable {
    private var frames: [Data] = []

    public init() {}

    public var pendingCount: Int { frames.count }

    public mutating func enqueue(_ frame: Data) { frames.append(frame) }

    public mutating func removeAll() { frames.removeAll() }

    /// Sends frames in order. A `false` from `send` stops the drain and keeps that frame and everything after it.
    public mutating func drain(send: (Data) -> Bool) {
        while let first = frames.first {
            guard send(first) else { return }
            frames.removeFirst()
        }
    }
}
