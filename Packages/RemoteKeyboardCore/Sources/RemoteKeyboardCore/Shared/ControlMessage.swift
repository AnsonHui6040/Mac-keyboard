import Foundation

/// What the Receiver tells the keyboard about its focus. `ready` means the focused field can take typed text.
public struct ReceiverStatus: Codable, Equatable, Sendable {
    public let ready: Bool
    public let appName: String?
    public let focusEpoch: UInt64
    /// Whether the Mac has granted Accessibility. Left out of the wire when true, so an unchanged Receiver sends the same
    /// bytes as before and a status without the key reads as trusted.
    public let trusted: Bool
    /// Whether the Mac's measurement mode is on (Debug builds of the Receiver only; a Release Receiver never sets it). Left
    /// out of the wire when false, so a status without the key reads as off.
    public let measure: Bool
    /// The Mac accepts touchpad control from this connection; the value is the grant the keyboard must repeat in its
    /// `pointerOpen`. Absent while the Mac's switch is off, so a status of a Receiver without the touchpad is unchanged.
    public let pointerGrant: UInt32?
    /// Typing cannot go anywhere right now: the focused field is a password field, secure keyboard input is on, or the
    /// screen is locked. Left out of the wire when false, so a status without the key reads as not blocked.
    public let inputBlocked: Bool

    public init(
        ready: Bool, appName: String?, focusEpoch: UInt64, trusted: Bool = true, measure: Bool = false, pointerGrant: UInt32? = nil,
        inputBlocked: Bool = false
    ) {
        self.ready = ready
        self.appName = appName
        self.focusEpoch = focusEpoch
        self.trusted = trusted
        self.measure = measure
        self.pointerGrant = pointerGrant
        self.inputBlocked = inputBlocked
    }

    private enum CodingKeys: String, CodingKey { case ready, appName, focusEpoch, trusted, measure, pointerGrant, inputBlocked }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ready = try c.decode(Bool.self, forKey: .ready)
        appName = try c.decodeIfPresent(String.self, forKey: .appName)
        focusEpoch = try c.decode(UInt64.self, forKey: .focusEpoch)
        trusted = try c.decodeIfPresent(Bool.self, forKey: .trusted) ?? true
        measure = try c.decodeIfPresent(Bool.self, forKey: .measure) ?? false
        pointerGrant = try c.decodeIfPresent(UInt32.self, forKey: .pointerGrant)
        inputBlocked = try c.decodeIfPresent(Bool.self, forKey: .inputBlocked) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ready, forKey: .ready)
        try c.encodeIfPresent(appName, forKey: .appName)
        try c.encode(focusEpoch, forKey: .focusEpoch)
        if !trusted { try c.encode(false, forKey: .trusted) }
        if measure { try c.encode(true, forKey: .measure) }
        try c.encodeIfPresent(pointerGrant, forKey: .pointerGrant)
        if inputBlocked { try c.encode(true, forKey: .inputBlocked) }
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
    /// The Mac is about to end this connection on purpose (stop receiving, idle timeout, unpair, quit). Only ever sent
    /// inside `sealed`, so a bystander cannot make a keyboard drop its link. The keyboard answers with a full link reset.
    case bye
    /// After authentication every `ack`, `status` and `bye` travels here: `SessionCrypto` (`.macToPhone`) over the encoded
    /// inner message. Only those three are allowed inside.
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
