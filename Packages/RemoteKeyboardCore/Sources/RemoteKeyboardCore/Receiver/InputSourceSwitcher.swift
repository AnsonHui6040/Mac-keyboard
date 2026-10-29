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

/// Forces an ASCII layout around an injection so an IME (e.g. Zhuyin) cannot swallow the characters.
@MainActor
public struct InputSourceSwitcher {
    public static let asciiID = "com.apple.keylayout.ABC"
    public static let defaultSettleSeconds = 0.05

    private let controller: InputSourceControlling
    private let settle: (Double) async -> Void

    public init(controller: InputSourceControlling, settle: @escaping (Double) async -> Void) {
        self.controller = controller
        self.settle = settle
    }

    public func withASCII(
        settleSeconds: Double = InputSourceSwitcher.defaultSettleSeconds,
        _ inject: () -> Void
    ) async -> SwitchResult {
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
