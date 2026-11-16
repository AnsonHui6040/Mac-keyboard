import Darwin
import Foundation

/// Makes iOS ask for the 「區域網路」 permission while the App is in front (spec W12, F3).
///
/// The keyboard extension uses the permission the host App holds (F2), but a process that is not in the foreground is refused
/// without a prompt while the answer is still open. So the App touches the local network itself, from its settings page,
/// the way Apple's TN3179 describes: a UDP socket is connected to the link-local IPv6 address of each broadcast-capable
/// interface on port 9 (the discard port). `connect` on a UDP socket only sets the default destination: no datagram is sent.
/// It is done every time the page opens with the switch on and every time the switch is turned on, with no memory of having
/// done it: the system shows its alert only once, and an attempt that found no interface (no Wi-Fi at that moment) must be
/// able to try again. The permission is the system's to remember; there is no way to read it back.
enum LocalNetworkPermission {
    /// Touches the local network so that the system asks, if it has not been answered yet.
    static func trigger() {
        for address in linkLocalDestinations() {
            let descriptor = socket(AF_INET6, SOCK_DGRAM, 0)
            guard descriptor >= 0 else { continue }
            var destination = address
            _ = withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            close(descriptor)
        }
    }

    /// Link-local IPv6 addresses of interfaces that are up and can broadcast, with the port set to 9.
    private static func linkLocalDestinations() -> [sockaddr_in6] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var found: [sockaddr_in6] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let flags = entry.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0, flags & UInt32(IFF_BROADCAST) != 0, flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = entry.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_INET6
            else { continue }
            var destination = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            let bytes = withUnsafeBytes(of: destination.sin6_addr) { Array($0) }
            // fe80::/10
            guard bytes.count == 16, bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 else { continue }
            destination.sin6_port = UInt16(9).bigEndian
            found.append(destination)
        }
        return found
    }
}
