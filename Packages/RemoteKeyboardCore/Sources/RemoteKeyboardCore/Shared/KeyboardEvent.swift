import Foundation

/// What one key press means, independent of the key layout that produced it.
public enum EventKind: Codable, Equatable, Sendable {
    case text(String)
    case backspace
    case returnKey
    /// Latency probe; the Receiver acknowledges it without injecting anything.
    case ping(shownAtMs: Int64, connectedAtMs: Int64)

    /// Short wire keys: with the two UUIDs a probe is otherwise over the smallest notify payload (182 bytes).
    enum PingCodingKeys: String, CodingKey {
        case shownAtMs = "s"
        case connectedAtMs = "c"
    }

    /// A probe is not typed text, so it is sent without a focus epoch and the Receiver never ties it to a field.
    public var carriesFocusEpoch: Bool {
        if case .ping = self { return false }
        return true
    }
}

/// One semantic event sent from the keyboard to the Receiver over the `event` notification.
public struct KeyboardEvent: Codable, Equatable, Sendable {
    public static let currentVersion = 2

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

/// Everything the keyboard sends to the Receiver over `event`. T09 adds cases.
///
/// On the wire the event's own fields sit at the top level next to a `type` key, so `protocolVersion` is readable
/// before anything else is decoded.
public enum PeripheralMessage: Codable, Equatable, Sendable {
    case event(KeyboardEvent)

    private enum CodingKeys: String, CodingKey { case type }
    private static let eventType = "event"

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(String.self, forKey: .type) == Self.eventType else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "unknown message type")
        }
        self = .event(try KeyboardEvent(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .event(let event):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(Self.eventType, forKey: .type)
            try event.encode(to: encoder)
        }
    }
}

/// Protocol v2 message codec. The size limit is `FrameCodec.maxMessageBytes`; the BLE payload size is not its concern.
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
