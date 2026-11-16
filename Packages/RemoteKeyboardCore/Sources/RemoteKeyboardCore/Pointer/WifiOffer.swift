import Foundation

/// Where the Receiver may send Wi-Fi probes: the iPhone's IPv4 addresses and the UDP port of its listener. It travels in
/// the optional `wifi` field of `pointerOpen` (docs/protocol/v4.md §3.4, spec W2, §5.1) and is checked the same way in
/// `rk-core`: one to four dotted-decimal addresses, none of them `0.0.0.0`, a loopback, the broadcast or a multicast
/// address, and a port from 1 to 65535.
public struct WifiOffer: Equatable, Sendable {
    public static let maxAddresses = 4

    public let addrs: [String]
    public let port: UInt16

    /// `nil` when the addresses or the port break the rules above. Only the canonical spelling is accepted: four decimal
    /// octets from 0 to 255 and no leading zeros, so a Receiver that parses strictly reads exactly what was written.
    public init?(addrs: [String], port: UInt16) {
        guard (1...Self.maxAddresses).contains(addrs.count), port != 0, addrs.allSatisfy(Self.isUsableAddress) else { return nil }
        self.addrs = addrs
        self.port = port
    }

    static func isUsableAddress(_ text: String) -> Bool {
        guard let octets = octets(of: text) else { return false }
        if octets == [0, 0, 0, 0] || octets == [255, 255, 255, 255] { return false }
        if octets[0] == 127 { return false }
        return !(224...239).contains(octets[0])
    }

    private static func octets(of text: String) -> [UInt8]? {
        let parts = text.utf8.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                  part.count == 1 || part.first != UInt8(ascii: "0"), let value = UInt8(String(decoding: part, as: UTF8.self))
            else { return nil }
            octets.append(value)
        }
        return octets
    }
}

extension WifiOffer: Codable {
    private enum CodingKeys: String, CodingKey { case addrs, port }

    /// Throws when the fields are missing, mistyped or break the rules; `EventKind` turns that into "no `wifi`".
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let addrs = try container.decode([String].self, forKey: .addrs)
        let port = try container.decode(UInt16.self, forKey: .port)
        guard let offer = WifiOffer(addrs: addrs, port: port) else {
            throw DecodingError.dataCorruptedError(forKey: .addrs, in: container, debugDescription: "not a usable Wi-Fi offer")
        }
        self = offer
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(addrs, forKey: .addrs)
        try container.encode(port, forKey: .port)
    }
}
