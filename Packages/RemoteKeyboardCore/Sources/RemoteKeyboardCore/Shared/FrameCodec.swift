import Foundation

public enum FrameError: Error, Equatable, Sendable {
    /// `maxFrameBytes` leaves no room for payload after the header, or a received frame is shorter than the header.
    case frameTooSmall
    /// More bytes than one message may carry (or than 255 frames can hold). Carries the payload size.
    case payloadTooLarge(Int)
    /// Wrong version byte or a zero frame count, or a frame that continues a message that is not in progress.
    case badHeader
    case badIndex
    /// The frame count changed inside one message.
    case countMismatch
    case duplicateIndex
    case messageTooLarge
}

/// Splits one encoded message into BLE notifications.
///
/// Frame layout: `[0]` version `0x02`, `[1-2]` message id (UInt16, big-endian), `[3]` index, `[4]` count (1-255),
/// then a slice of the message. The index and count let the Receiver tell a complete message from a lost frame.
public enum FrameCodec {
    public static let headerBytes = 5
    public static let maxMessageBytes = 16_384
    public static let maxFrameCount = 255
    static let frameVersion: UInt8 = 0x02

    /// - Parameter maxFrameBytes: the subscribed central's `maximumUpdateValueLength`, header included.
    public static func split(_ payload: Data, messageId: UInt16, maxFrameBytes: Int) throws -> [Data] {
        guard maxFrameBytes > headerBytes else { throw FrameError.frameTooSmall }
        guard payload.count <= maxMessageBytes else { throw FrameError.payloadTooLarge(payload.count) }
        let slice = maxFrameBytes - headerBytes
        let count = max(1, (payload.count + slice - 1) / slice)
        guard count <= maxFrameCount else { throw FrameError.payloadTooLarge(payload.count) }
        let bytes = [UInt8](payload)
        return (0..<count).map { index in
            let start = index * slice
            let end = min(start + slice, bytes.count)
            var frame = Data([frameVersion, UInt8(messageId >> 8), UInt8(messageId & 0xFF), UInt8(index), UInt8(count)])
            frame.append(contentsOf: bytes[start..<end])
            return frame
        }
    }
}
