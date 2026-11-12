import Foundation

/// What one key press means, independent of the key layout that produced it.
public enum EventKind: Codable, Equatable, Sendable {
    case text(String)
    case backspace
    case returnKey
    /// Latency probe; the Receiver acknowledges it without injecting anything.
    case ping(shownAtMs: Int64, connectedAtMs: Int64)
    /// Liveness probe sent when a keyboard appears on a link that may be dead. The Receiver answers `pong` and does
    /// nothing else: no reconnect sample, no deduplication record, no injection.
    case probe
    /// The keyboard shows the touchpad page and asks the Receiver to accept `0x03` pointer packets. `grant` is the
    /// `ReceiverStatus.pointerGrant` the keyboard last read. Answered at once with `posted` or `notAuthorized`.
    case pointerOpen(grant: UInt32)
    /// The touchpad page is left. The Receiver stops accepting pointer packets and lets go of anything held.
    case pointerClose

    /// Short wire keys: with the two UUIDs a probe is otherwise over the smallest notify payload (182 bytes).
    enum PingCodingKeys: String, CodingKey {
        case shownAtMs = "s"
        case connectedAtMs = "c"
    }

    /// A probe is not typed text, so it is sent without a focus epoch and the Receiver never ties it to a field.
    public var carriesFocusEpoch: Bool {
        switch self {
        case .ping, .probe, .pointerOpen, .pointerClose: return false
        case .text, .backspace, .returnKey: return true
        }
    }
}

/// One semantic event sent from the keyboard to the Receiver over the `event` notification.
public struct KeyboardEvent: Codable, Equatable, Sendable {
    public static let currentVersion = 4

    public let protocolVersion: Int
    public let eventId: UUID
    /// One per keyboard appearance (peripheral session).
    public let sessionId: UUID
    /// Starts at 1 within a session.
    public let seq: UInt64
    /// The Receiver focus epoch the key was typed against, or `nil` when no status has arrived yet.
    public let focusEpoch: UInt64?
    public let kind: EventKind

    public init(protocolVersion: Int, eventId: UUID, sessionId: UUID, seq: UInt64, focusEpoch: UInt64?, kind: EventKind) {
        self.protocolVersion = protocolVersion
        self.eventId = eventId
        self.sessionId = sessionId
        self.seq = seq
        self.focusEpoch = focusEpoch
        self.kind = kind
    }
}

public enum EventCodecError: Error, Equatable, Sendable {
    case unsupportedVersion(Int)
    case tooLarge(Int)
    case malformed
}

/// JSON codec of a single `KeyboardEvent`. The wire carries it inside a `PeripheralMessage` (see `PeripheralCodec`),
/// split into frames by `FrameCodec`.
public enum EventCodec {
    private struct Header: Decodable { let protocolVersion: Int }

    /// - Parameter maxBytes: the subscribed central's `maximumUpdateValueLength`.
    public static func encode(_ e: KeyboardEvent, maxBytes: Int) throws -> Data {
        let data: Data
        do { data = try makeEncoder().encode(e) } catch { throw EventCodecError.malformed }
        guard data.count <= maxBytes else { throw EventCodecError.tooLarge(data.count) }
        return data
    }

    public static func decode(_ d: Data) throws -> KeyboardEvent {
        let decoder = JSONDecoder()
        // The version is checked before the full shape, so a future version never reads as merely "malformed".
        guard let header = try? decoder.decode(Header.self, from: d) else { throw EventCodecError.malformed }
        guard header.protocolVersion == KeyboardEvent.currentVersion else {
            throw EventCodecError.unsupportedVersion(header.protocolVersion)
        }
        guard let event = try? decoder.decode(KeyboardEvent.self, from: d) else { throw EventCodecError.malformed }
        return event
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

/// Everything the keyboard sends to the receiver over `event`.
///
/// On the wire every message is one flat JSON object with a `type` key and a top-level `protocolVersion`, so the version
/// is readable before anything else is decoded. Once a host is paired a `.event` only travels inside `.sealed` and the
/// receiver treats a bare `.event` as a protocol violation.
public enum PeripheralMessage: Codable, Equatable, Sendable {
    case event(KeyboardEvent)
    /// Pairing step 1: `Pairing.commitment` of the iPhone's ephemeral public key (32 bytes); the key itself follows later.
    case pairOffer(commitment: Data)
    /// Pairing step 3, after the host's `pairAccept`: the iPhone's public key (x9.63, 65 bytes) the commitment covers, and
    /// its identity. On the wire the identity fields sit beside the key (`phoneId`, `phoneName`, `phonePlatform`).
    case pairReveal(publicKey: Data, phone: PhoneIdentity)
    /// Answer to the host's `hello`: the iPhone's nonce (16 bytes) and its proof (32 bytes).
    case helloReply(phoneNonce: Data, proof: Data)
    /// Answer to a `hello` meant for another host: this keyboard is not typing to the host that wrote it. Plain, keeps no
    /// state, and the same whether or not the iPhone was ever paired with that host.
    case notSelected
    /// `SessionCrypto.seal` output over a `PeripheralCodec`-encoded `.event`.
    case sealed(Data)

    private enum CodingKeys: String, CodingKey {
        case type, protocolVersion, commitment, publicKey, phoneNonce, proof, payload, phoneId, phoneName, phonePlatform
    }
    private enum WireType: String {
        case event, pairOffer, pairReveal, helloReply, notSelected, sealed
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let type = WireType(rawValue: try container.decode(String.self, forKey: .type)) else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown message type")
        }
        switch type {
        case .event:
            self = .event(try KeyboardEvent(from: decoder))
        case .pairOffer:
            self = .pairOffer(commitment: try container.decode(Data.self, forKey: .commitment))
        case .pairReveal:
            self = .pairReveal(
                publicKey: try container.decode(Data.self, forKey: .publicKey),
                phone: PhoneIdentity(
                    id: try container.decode(Data.self, forKey: .phoneId), name: try container.decode(String.self, forKey: .phoneName),
                    platform: try container.decode(PhonePlatform.self, forKey: .phonePlatform)))
        case .helloReply:
            self = .helloReply(
                phoneNonce: try container.decode(Data.self, forKey: .phoneNonce), proof: try container.decode(Data.self, forKey: .proof))
        case .notSelected:
            self = .notSelected
        case .sealed:
            self = .sealed(try container.decode(Data.self, forKey: .payload))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .event(let event):
            try container.encode(WireType.event.rawValue, forKey: .type)
            try event.encode(to: encoder)
        case .pairOffer(let commitment):
            try container.encode(WireType.pairOffer.rawValue, forKey: .type)
            try container.encode(KeyboardEvent.currentVersion, forKey: .protocolVersion)
            try container.encode(commitment, forKey: .commitment)
        case .pairReveal(let publicKey, let phone):
            try container.encode(WireType.pairReveal.rawValue, forKey: .type)
            try container.encode(KeyboardEvent.currentVersion, forKey: .protocolVersion)
            try container.encode(publicKey, forKey: .publicKey)
            try container.encode(phone.id, forKey: .phoneId)
            try container.encode(phone.name, forKey: .phoneName)
            try container.encode(phone.platform, forKey: .phonePlatform)
        case .helloReply(let phoneNonce, let proof):
            try container.encode(WireType.helloReply.rawValue, forKey: .type)
            try container.encode(KeyboardEvent.currentVersion, forKey: .protocolVersion)
            try container.encode(phoneNonce, forKey: .phoneNonce)
            try container.encode(proof, forKey: .proof)
        case .notSelected:
            try container.encode(WireType.notSelected.rawValue, forKey: .type)
            try container.encode(KeyboardEvent.currentVersion, forKey: .protocolVersion)
        case .sealed(let payload):
            try container.encode(WireType.sealed.rawValue, forKey: .type)
            try container.encode(KeyboardEvent.currentVersion, forKey: .protocolVersion)
            try container.encode(payload, forKey: .payload)
        }
    }
}

/// Protocol v4 message codec. The size limit is `FrameCodec.maxMessageBytes`; the BLE payload size is not its concern.
public enum PeripheralCodec {
    private struct Header: Decodable { let protocolVersion: Int }

    public static func encode(_ m: PeripheralMessage) throws -> Data {
        let data: Data
        do { data = try EventCodec.makeEncoder().encode(m) } catch { throw EventCodecError.malformed }
        guard data.count <= FrameCodec.maxMessageBytes else { throw EventCodecError.tooLarge(data.count) }
        return data
    }

    public static func decode(_ d: Data) throws -> PeripheralMessage {
        let decoder = JSONDecoder()
        // The version is checked before the full shape, so a future version never reads as merely "malformed".
        guard let header = try? decoder.decode(Header.self, from: d) else { throw EventCodecError.malformed }
        guard header.protocolVersion == KeyboardEvent.currentVersion else {
            throw EventCodecError.unsupportedVersion(header.protocolVersion)
        }
        guard let message = try? decoder.decode(PeripheralMessage.self, from: d) else { throw EventCodecError.malformed }
        return message
    }
}
