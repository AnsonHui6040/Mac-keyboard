import Foundation

public enum ReceiverSessionInput: Equatable {
    case start, stop
}

public enum ReceiverSessionEffect: Equatable {
    case arm, disarm
}

/// D29: the Receiver listens from launch until the user pauses it. There is no idle timeout.
public struct ReceiverSession {
    public private(set) var isArmed = false

    public init() {}

    public mutating func handle(_ input: ReceiverSessionInput) -> [ReceiverSessionEffect] {
        switch input {
        case .start:
            guard !isArmed else { return [] }
            isArmed = true
            return [.arm]
        case .stop:
            guard isArmed else { return [] }
            isArmed = false
            return [.disarm]
        }
    }
}
