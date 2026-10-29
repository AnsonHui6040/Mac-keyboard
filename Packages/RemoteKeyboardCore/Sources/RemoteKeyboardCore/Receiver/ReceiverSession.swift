import Foundation

public enum ReceiverSessionInput: Equatable {
    case editableFocusGained, eventReceived, manualStart, manualStop, timerFired
}

public enum ReceiverSessionEffect: Equatable {
    case arm, disarm, scheduleTimeout(at: Date)
}

/// Decides when the resident Receiver listens. Time is injected, never read here.
public struct ReceiverSession {
    public static let idleTimeout: TimeInterval = 1800

    public private(set) var isArmed = false
    public private(set) var deadline: Date?
    private let idleTimeout: TimeInterval

    public init(idleTimeout: TimeInterval = ReceiverSession.idleTimeout) {
        self.idleTimeout = idleTimeout
    }

    public mutating func handle(_ input: ReceiverSessionInput, now: Date) -> [ReceiverSessionEffect] {
        switch input {
        case .editableFocusGained, .manualStart:
            let wasArmed = isArmed
            isArmed = true
            let next = now.addingTimeInterval(idleTimeout)
            deadline = next
            return (wasArmed ? [] : [.arm]) + [.scheduleTimeout(at: next)]
        case .eventReceived:
            guard isArmed else { return [] }
            let next = now.addingTimeInterval(idleTimeout)
            deadline = next
            return [.scheduleTimeout(at: next)]
        case .manualStop:
            guard isArmed else { return [] }
            return disarm()
        case .timerFired:
            guard isArmed, let deadline, now >= deadline else { return [] }
            return disarm()
        }
    }

    private mutating func disarm() -> [ReceiverSessionEffect] {
        isArmed = false
        deadline = nil
        return [.disarm]
    }
}
