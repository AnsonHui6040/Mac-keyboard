import Foundation
import OSLog

/// Seam over Text Input Sources. Main-actor because TIS must be called from the main thread.
@MainActor
public protocol InputSourceControlling {
    func currentID() -> String
    func select(_ id: String) -> Bool
}

/// Whether the focused field holds uncommitted IME text.
public enum CompositionState: Equatable, Sendable {
    case composing, notComposing, unknown
}

/// Seam over reading and cancelling an open IME composition. Main-actor because it reads Accessibility.
@MainActor
public protocol CompositionControlling {
    func state() -> CompositionState
    func cancel()
}

public enum SwitchResult: Equatable, Sendable {
    case injected, switchFailed
    /// A composition stayed open after cancelling it; nothing was switched or injected.
    case compositionActive
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
/// Composition rule (D4 revision): when the current source is not ABC and a composition is open, it is cancelled
/// (Escape) and given one settle delay. If it is still open the call refuses with `.compositionActive`. An `.unknown`
/// state does not block; it switches as before.
///
/// Serialization guarantee: overlapping `withASCII` calls on the same switcher (or any copy of it) run strictly one
/// after another, in call order. A later call does not read the current source, select, verify or inject until the
/// earlier call has finished its settle delay and restored the original source. Without this, a second call would see
/// ABC already active, inject with no settle of its own, and its events could land after the first call's restore.
@MainActor
public struct InputSourceSwitcher {
    public static let asciiID = "com.apple.keylayout.ABC"
    public static let defaultSettleSeconds = 0.05

    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard", category: "inputsource")

    private let controller: InputSourceControlling
    private let composition: CompositionControlling?
    private let settle: (Double) async -> Void
    private let gate = SerialGate()

    /// - Parameter composition: `nil` behaves as an always `.unknown` state.
    public init(
        controller: InputSourceControlling,
        composition: CompositionControlling? = nil,
        settle: @escaping (Double) async -> Void
    ) {
        self.controller = controller
        self.composition = composition
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
        if let composition, composition.state() == .composing {
            composition.cancel()
            await settle(settleSeconds)
            if composition.state() == .composing { return .compositionActive }
        }
        _ = controller.select(Self.asciiID)
        guard controller.currentID() == Self.asciiID else {
            // The switch did not take; put things back and refuse rather than type into an IME.
            restore(original)
            return .switchFailed
        }
        inject()
        await settle(settleSeconds)
        restore(original)
        return .injected
    }

    /// A failed restore leaves the user on ABC, so it is logged. Only input source IDs are logged, never text.
    private func restore(_ original: String) {
        if !controller.select(original) {
            Self.log.error("restore failed to \(original, privacy: .public)")
        }
    }
}
