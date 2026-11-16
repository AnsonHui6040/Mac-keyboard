import Darwin
import RemoteKeyboardCore

/// The iPhone's own IPv4 addresses for `pointerOpen.wifi`. `getifaddrs` lists every address of every interface; the rule
/// for which of them are offered (up, broadcast-capable, not a loopback, at most four) is `LocalIPv4Selection` in Core.
/// No interface name is looked at, because Wi-Fi is not `en0` on every device.
enum LocalAddresses {
    static func current() -> [String] { LocalIPv4Selection.pick(from: records()) }

    static func records() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var records: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr, Int32(address.pointee.sa_family) == AF_INET else { continue }
            var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let converted = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer -> Bool in
                var raw = pointer.pointee.sin_addr
                return inet_ntop(AF_INET, &raw, &text, socklen_t(text.count)) != nil
            }
            guard converted else { continue }
            let digits = text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            records.append(
                InterfaceAddress(flags: entry.pointee.ifa_flags, family: AF_INET, address: String(decoding: digits, as: UTF8.self)))
        }
        return records
    }
}
