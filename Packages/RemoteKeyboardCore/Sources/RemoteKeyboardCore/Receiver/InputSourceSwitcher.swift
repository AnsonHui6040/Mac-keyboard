import Foundation

/// Seam over Text Input Sources. Main-actor because TIS must be called from the main thread.
@MainActor
public protocol InputSourceControlling {
    func currentID() -> String
    func select(_ id: String) -> Bool
}

public enum SwitchResult: Equatable, Sendable {
    case injected, switchFailed
}

/// FIFO async mutex. Main-actor confined, so plain stored state is safe.
@MainActor
private final class SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            // Hand the lock straight to the next caller; `busy` stays true so nobody can slip in between.
            waiters.removeFirst().resume()
        }
    }
}

/// Forces an ASCII layout around an injection so an IME (e.g. Zhuyin) cannot swallow the characters.
///
/// Serialization guarantee: overlapping `withASCII` calls on the same switcher (or any copy of it) run strictly one
/// after another, in call order. A later call does not read the current source, select, verify or inject until the
/// earlier call has finished its settle delay and restored the original source. Without this, a second call would see
/// ABC already active, inject with no settle of its own, and its events could land after the first call's restore.
@MainActor
public struct InputSourceSwitcher {
    public static let asciiID = "com.apple.keylayout.ABC"
    public static let defaultSettleSeconds = 0.05

    private let controller: InputSourceControlling
    private let settle: (Double) async -> Void
    private let gate = SerialGate()

    public init(controller: InputSourceControlling, settle: @escaping (Double) async -> Void) {
        self.controller = controller
        self.settle = settle
    }

    public func withASCII(
        settleSeconds: Double = InputSourceSwitcher.defaultSettleSeconds,
        _ inject: () -> Void
    ) async -> SwitchResult {
        await gate.acquire()
        defer { gate.release() }
        let original = controller.currentID()
        if original == Self.asciiID {
            inject()
            return .injected
        }
        _ = controller.select(Self.asciiID)
        guard controller.currentID() == Self.asciiID else {
            // The switch did not take; put things back and refuse rather than type into an IME.
            _ = controller.select(original)
            return .switchFailed
        }
        inject()
        await settle(settleSeconds)
        _ = controller.select(original)
        return .injected
    }
}
