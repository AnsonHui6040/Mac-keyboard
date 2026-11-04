import Foundation

/// The three things the host App needs before the keyboard can type to a Mac, in the order the home screen shows them.
public struct SetupProgress: Equatable, Sendable {
    public enum Step: CaseIterable, Sendable {
        /// The Bluetooth permission for this App.
        case bluetooth
        /// A pair key is stored.
        case pairing
        /// The keyboard has appeared once with 「允許完整取用」 on.
        case keyboard
    }

    public struct Item: Equatable, Sendable {
        public let step: Step
        public let isDone: Bool
    }

    /// What the keyboard last ran into, when the three steps are done but typing still would not work.
    public enum ConnectionProblem: Equatable, Sendable {
        case authFailed
        case unreachable
    }

    public let steps: [Item]
    /// `nil` when nothing went wrong, and always `nil` while this iPhone is not paired: the pairing step says so.
    public let connectionProblem: ConnectionProblem?

    public init(bluetoothAllowed: Bool, isPaired: Bool, keyboardReady: Bool, lastLink: LastLinkResult? = nil) {
        steps = [
            Item(step: .bluetooth, isDone: bluetoothAllowed),
            Item(step: .pairing, isDone: isPaired),
            Item(step: .keyboard, isDone: keyboardReady),
        ]
        switch (isPaired, lastLink) {
        case (true, .authFailed?): connectionProblem = .authFailed
        case (true, .unreachable?): connectionProblem = .unreachable
        default: connectionProblem = nil
        }
    }

    public var isComplete: Bool { steps.allSatisfy(\.isDone) && connectionProblem == nil }
}
