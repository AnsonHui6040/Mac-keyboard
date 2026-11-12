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

/// Carried by the `control` characteristic (write with response), host to keyboard.
///
/// On the wire every message is an object with exactly one recognised key, the message name, whose value is the content
/// object (`{}` when there is none, `_0` for a single unnamed value); see docs/protocol/v4.md §3.2. The coding is written by
/// hand so that the identity fields of `pairAccept` sit beside `publicKey` instead of in a nested object, and so that an
/// object with zero or several recognised names is a format error.
public enum ControlMessage: Codable, Equatable, Sendable {
    case ack(Ack)
    case status(ReceiverStatus)
    /// Pairing step 2: the host's ephemeral public key (x9.63, 65 bytes) and its identity, the answer to `pairOffer`.
    case pairAccept(publicKey: Data, host: HostIdentity)
    /// Start of the challenge: the host the write is meant for (16 bytes) and its nonce (16 bytes).
    case hello(hostId: Data, hostNonce: Data)
    /// The host's proof (32 bytes) after it verified the iPhone's `helloReply`.
    case auth(proof: Data)
    /// The host rejected the iPhone and is about to disconnect.
    case authFailed
    /// The host is about to end this connection on purpose (stop receiving, idle timeout, unpair, quit). Only ever sent
    /// inside `sealed`, so a bystander cannot make a keyboard drop its link. The keyboard answers with a full link reset.
    case bye
    /// After authentication every `ack`, `status` and `bye` travels here: `SessionCrypto` (`.macToPhone`) over the encoded
    /// inner message. Only those three are allowed inside.
    case sealed(Data)

    private enum Name: String, CaseIterable {
        case ack, status, pairAccept, hello, auth, authFailed, bye, sealed
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private enum Single: String, CodingKey { case value = "_0" }
    private enum AcceptKeys: String, CodingKey { case hostId, hostName, platform, publicKey }
    private enum HelloKeys: String, CodingKey { case hostId, hostNonce }
    private enum AuthKeys: String, CodingKey { case proof }

    public init(from decoder: Decoder) throws {
        let outer = try decoder.container(keyedBy: AnyKey.self)
        let names = Name.allCases.filter { outer.contains(AnyKey($0.rawValue)) }
        guard names.count == 1, let name = names.first else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "exactly one recognised message name is required"))
        }
        let key = AnyKey(name.rawValue)
        switch name {
        case .ack:
            self = .ack(try outer.nestedContainer(keyedBy: Single.self, forKey: key).decode(Ack.self, forKey: .value))
        case .status:
            self = .status(try outer.nestedContainer(keyedBy: Single.self, forKey: key).decode(ReceiverStatus.self, forKey: .value))
        case .pairAccept:
            let c = try outer.nestedContainer(keyedBy: AcceptKeys.self, forKey: key)
            self = .pairAccept(
                publicKey: try c.decode(Data.self, forKey: .publicKey),
                host: HostIdentity(
                    id: try c.decode(Data.self, forKey: .hostId), name: try c.decode(String.self, forKey: .hostName),
                    platform: try c.decode(HostPlatform.self, forKey: .platform)))
        case .hello:
            let c = try outer.nestedContainer(keyedBy: HelloKeys.self, forKey: key)
            self = .hello(hostId: try c.decode(Data.self, forKey: .hostId), hostNonce: try c.decode(Data.self, forKey: .hostNonce))
        case .auth:
            self = .auth(proof: try outer.nestedContainer(keyedBy: AuthKeys.self, forKey: key).decode(Data.self, forKey: .proof))
        case .authFailed:
            _ = try outer.nestedContainer(keyedBy: AnyKey.self, forKey: key)
            self = .authFailed
        case .bye:
            _ = try outer.nestedContainer(keyedBy: AnyKey.self, forKey: key)
            self = .bye
        case .sealed:
            self = .sealed(try outer.nestedContainer(keyedBy: Single.self, forKey: key).decode(Data.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var outer = encoder.container(keyedBy: AnyKey.self)
        switch self {
        case .ack(let ack):
            var c = outer.nestedContainer(keyedBy: Single.self, forKey: AnyKey(Name.ack.rawValue))
            try c.encode(ack, forKey: .value)
        case .status(let status):
            var c = outer.nestedContainer(keyedBy: Single.self, forKey: AnyKey(Name.status.rawValue))
            try c.encode(status, forKey: .value)
        case .pairAccept(let publicKey, let host):
            var c = outer.nestedContainer(keyedBy: AcceptKeys.self, forKey: AnyKey(Name.pairAccept.rawValue))
            try c.encode(host.id, forKey: .hostId)
            try c.encode(host.name, forKey: .hostName)
            try c.encode(host.platform, forKey: .platform)
            try c.encode(publicKey, forKey: .publicKey)
        case .hello(let hostId, let hostNonce):
            var c = outer.nestedContainer(keyedBy: HelloKeys.self, forKey: AnyKey(Name.hello.rawValue))
            try c.encode(hostId, forKey: .hostId)
            try c.encode(hostNonce, forKey: .hostNonce)
        case .auth(let proof):
            var c = outer.nestedContainer(keyedBy: AuthKeys.self, forKey: AnyKey(Name.auth.rawValue))
            try c.encode(proof, forKey: .proof)
        case .authFailed:
            _ = outer.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(Name.authFailed.rawValue))
        case .bye:
            _ = outer.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(Name.bye.rawValue))
        case .sealed(let payload):
            var c = outer.nestedContainer(keyedBy: Single.self, forKey: AnyKey(Name.sealed.rawValue))
            try c.encode(payload, forKey: .value)
        }
    }
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
