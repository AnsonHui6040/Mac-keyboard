import Foundation

/// The Shift key: one tap capitalises the next letter, a quick second tap locks capitals, a tap on the lock releases it.
public struct ShiftState: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case off
        case once
        case capsLock
    }

    /// Two taps this close (inclusive) count as a double tap.
    public static let doubleTapInterval: TimeInterval = 0.3
    /// Floating point slack, so two taps exactly 0.3 s apart (10.0 and 10.3) still count.
    private static let tolerance: TimeInterval = 1e-9

    public private(set) var mode: Mode = .off
    private var lastTap: TimeInterval?

    public init() {}

    public var isUppercase: Bool { mode != .off }

    /// - Parameter time: any monotonic time in seconds, such as `ProcessInfo.systemUptime`.
    public mutating func tap(at time: TimeInterval) {
        defer { lastTap = time }
        switch mode {
        case .off:
            mode = .once
        case .once:
            let isDouble = lastTap.map { time - $0 <= Self.doubleTapInterval + Self.tolerance } ?? false
            mode = isDouble ? .capsLock : .off
        case .capsLock:
            mode = .off
        }
    }

    /// A letter was typed: a single capital is used up, Caps Lock stays.
    public mutating func characterTyped() {
        if mode == .once { mode = .off }
    }
}
