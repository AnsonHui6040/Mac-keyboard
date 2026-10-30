import Foundation

public enum ReassemblyResult: Equatable, Sendable {
    case incomplete
    case complete(Data)
    case rejected(FrameError)
}

/// Puts the frames of one message back together. One reassembler per connected peripheral; it holds one message at a
/// time and must be `reset()` whenever that connection ends.
public struct FrameReassembler: Sendable {
    private struct Partial: Sendable {
        let messageId: UInt16
        let count: Int
        var slices: [Data?]
        var received = 0
        var bytes = 0
    }

    private let maxMessageBytes: Int
    private var partial: Partial?
    /// How many unfinished messages were thrown away because a new message's first frame arrived.
    public private(set) var droppedPartialMessages = 0

    public init(maxMessageBytes: Int = FrameCodec.maxMessageBytes) {
        self.maxMessageBytes = maxMessageBytes
    }

    public mutating func reset() { partial = nil }

    /// Rejections never deliver partial data. A rejected frame leaves the message in progress alone, except that an
    /// oversize message is dropped. A first frame with a new message id discards the unfinished message (counted in
    /// `droppedPartialMessages`) and is then handled as the start of the new message, so that message is not lost.
    public mutating func accept(_ frame: Data) -> ReassemblyResult {
        let bytes = [UInt8](frame)
        guard bytes.count >= FrameCodec.headerBytes else { return .rejected(.frameTooSmall) }
        guard bytes[0] == FrameCodec.frameVersion else { return .rejected(.badHeader) }
        let messageId = UInt16(bytes[1]) << 8 | UInt16(bytes[2])
        let index = Int(bytes[3])
        let count = Int(bytes[4])
        guard count >= 1 else { return .rejected(.badHeader) }
        guard index < count else { return .rejected(.badIndex) }
        let slice = Data(bytes[FrameCodec.headerBytes...])

        if var current = partial {
            if current.messageId != messageId {
                // Only a first frame can start a message.
                guard index == 0 else { return .rejected(.badHeader) }
                partial = nil
                droppedPartialMessages += 1
                return start(messageId: messageId, count: count, slice: slice)
            }
            guard current.count == count else { return .rejected(.countMismatch) }
            guard current.slices[index] == nil else { return .rejected(.duplicateIndex) }
            current.slices[index] = slice
            current.received += 1
            current.bytes += slice.count
            guard current.bytes <= maxMessageBytes else {
                partial = nil
                return .rejected(.messageTooLarge)
            }
            return finish(current)
        }

        guard index == 0 else { return .rejected(.badHeader) }
        return start(messageId: messageId, count: count, slice: slice)
    }

    private mutating func start(messageId: UInt16, count: Int, slice: Data) -> ReassemblyResult {
        guard slice.count <= maxMessageBytes else { return .rejected(.messageTooLarge) }
        var started = Partial(messageId: messageId, count: count, slices: Array(repeating: nil, count: count))
        started.slices[0] = slice
        started.received = 1
        started.bytes = slice.count
        return finish(started)
    }

    private mutating func finish(_ current: Partial) -> ReassemblyResult {
        guard current.received == current.count else {
            partial = current
            return .incomplete
        }
        partial = nil
        var message = Data(capacity: current.bytes)
        for slice in current.slices { message.append(slice ?? Data()) }
        return .complete(message)
    }
}
