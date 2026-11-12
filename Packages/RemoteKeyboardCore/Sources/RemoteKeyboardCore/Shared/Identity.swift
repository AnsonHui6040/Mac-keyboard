import Foundation

// Who is on each end of a pairing (docs/protocol/v4.md §4). A host (the Mac, Windows or Linux receiver) and a phone each
// have a random 16-byte id, a display name of at most 32 UTF-8 bytes and a platform string. The platform enums carry the
// wire strings, so a string the protocol does not list cannot be decoded at all.

public enum HostPlatform: String, Codable, Equatable, Sendable { case mac, windows, linux }
public enum PhonePlatform: String, Codable, Equatable, Sendable { case ios, android }

public enum IdentityName {
    /// Longest name on the wire, in UTF-8 bytes.
    public static let maxBytes = 32
    /// Length of `hostId` and `phoneId`.
    public static let idLength = 16

    /// The longest prefix of `name` that fits in `maxBytes` UTF-8 bytes, cut on a Unicode scalar boundary: a multi-scalar
    /// character (an emoji joined with U+200D, a letter with a combining mark) may be cut in two, but the result is always
    /// valid UTF-8. Whoever owns the name applies this once, when storing it; a name emptied by the user falls back to a
    /// default name instead (not this function's business).
    public static func clamp(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        var bytes = 0
        for scalar in name.unicodeScalars {
            let width = UTF8.width(scalar)
            guard bytes + width <= maxBytes else { break }
            bytes += width
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// A name that may travel and be stored: not empty, at most `maxBytes` UTF-8 bytes. A received name that fails this makes
    /// the pairing fail; the receiver never repairs it.
    public static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= maxBytes
    }
}

/// The host side of a pairing. `Codable` is for local storage only; the wire shape is flat and lives in `ControlMessage`.
public struct HostIdentity: Codable, Equatable, Sendable {
    public let id: Data
    public let name: String
    public let platform: HostPlatform

    public init(id: Data, name: String, platform: HostPlatform) {
        self.id = id
        self.name = name
        self.platform = platform
    }

    /// 16-byte id and a valid name; what a pairing checks in what it receives.
    public var isValid: Bool { id.count == IdentityName.idLength && IdentityName.isValid(name) }
}

/// The phone side of a pairing. `Codable` is for local storage only.
public struct PhoneIdentity: Codable, Equatable, Sendable {
    public let id: Data
    public let name: String
    public let platform: PhonePlatform

    public init(id: Data, name: String, platform: PhonePlatform) {
        self.id = id
        self.name = name
        self.platform = platform
    }

    public var isValid: Bool { id.count == IdentityName.idLength && IdentityName.isValid(name) }
}
