import Foundation

/// What the Receiver tells the keyboard about its focus. `ready` means the focused field can take typed text.
public struct ReceiverStatus: Codable, Equatable, Sendable {
    public let ready: Bool
    public let appName: String?
    public let focusEpoch: UInt64

    public init(ready: Bool, appName: String?, focusEpoch: UInt64) {
        self.ready = ready
        self.appName = appName
        self.focusEpoch = focusEpoch
    }
}

/// The Receiver's answer to one event. It means only that the Receiver processed the event.
public struct Ack: Codable, Equatable, Sendable {
    /// Used when the event could not be decoded far enough to know its id.
    public static let unknownEventId = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    public let eventId: UUID
    public let result: AckCode

    public init(eventId: UUID, result: AckCode) {
        self.eventId = eventId
        self.result = result
    }
}

/// Carried by the `control` characteristic (write with response), Receiver to keyboard.
public enum ControlMessage: Codable, Equatable, Sendable {
    case ack(Ack)
    case status(ReceiverStatus)
    /// Pairing step 2: the Mac's ephemeral public key (x9.63, 65 bytes), the answer to `pairOffer`.
    case pairAccept(publicKey: Data)
    /// Start of the challenge: the Mac's nonce (16 bytes).
    case hello(macNonce: Data)
    /// The Mac's proof (32 bytes) after it verified the iPhone's `helloReply`.
    case auth(proof: Data)
    /// The Mac rejected the iPhone and is about to disconnect.
    case authFailed
    /// After authentication every `ack` and `status` travels here: `SessionCrypto` (`.macToPhone`) over the encoded inner
    /// message. Only `ack` and `status` are allowed inside.
    case sealed(Data)
}

public enum ControlCodec {
    public static func encode(_ m: ControlMessage) throws -> Data {
        do { return try EventCodec.makeEncoder().encode(m) } catch { throw EventCodecError.malformed }
    }

    public static func decode(_ d: Data) throws -> ControlMessage {
        guard let message = try? JSONDecoder().decode(ControlMessage.self, from: d) else { throw EventCodecError.malformed }
        return message
    }
}
