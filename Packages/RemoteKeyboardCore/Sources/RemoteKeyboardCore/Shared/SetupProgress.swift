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

    public let steps: [Item]

    public init(bluetoothAllowed: Bool, isPaired: Bool, keyboardReady: Bool) {
        steps = [
            Item(step: .bluetooth, isDone: bluetoothAllowed),
            Item(step: .pairing, isDone: isPaired),
            Item(step: .keyboard, isDone: keyboardReady),
        ]
    }

    public var isComplete: Bool { steps.allSatisfy(\.isDone) }
}
