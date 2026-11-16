import Foundation

/// One address of one network interface as `getifaddrs` reports it: the interface flags, the address family and the
/// address in dotted-decimal form (IPv4) or whatever text the caller made of it. The interface's name is not here on
/// purpose: Wi-Fi is `en0` on most iPhones, but nothing may depend on that.
public struct InterfaceAddress: Equatable, Sendable {
    public let flags: UInt32
    public let family: Int32
    public let address: String

    public init(flags: UInt32, family: Int32, address: String) {
        self.flags = flags
        self.family = family
        self.address = address
    }
}

/// Which of the iPhone's own addresses are offered to the Receiver in `pointerOpen.wifi` (spec §6.4): IPv4 on an interface
/// that is up and can broadcast and is not a loopback, an address `WifiOffer` accepts, no repeats, in the order the system gave
/// them, at most `limit`. Pure, so the rule is tested without a network.
public enum LocalIPv4Selection {
    public static let limit = WifiOffer.maxAddresses

    public static func pick(from records: [InterfaceAddress]) -> [String] {
        let required = UInt32(IFF_UP | IFF_BROADCAST)
        let forbidden = UInt32(IFF_LOOPBACK)
        var picked: [String] = []
        for record in records where picked.count < limit {
            guard record.family == AF_INET,
                  record.flags & required == required, record.flags & forbidden == 0,
                  WifiOffer.isUsableAddress(record.address), !picked.contains(record.address)
            else { continue }
            picked.append(record.address)
        }
        return picked
    }
}
