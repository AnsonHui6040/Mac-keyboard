import CryptoKit
import Foundation

public enum SelectUUID {
    private static let label = Data("rk-select".utf8)

    /// The service UUID the keyboard advertises for the host it currently types to (docs/protocol/v4.md §1.3): the first 16
    /// bytes of SHA-256("rk-select" ‖ hostId), with the version nibble set to 4 and the variant bits to `10`.
    public static func make(hostId: Data) -> UUID {
        var b = [UInt8](SHA256.hash(data: label + hostId).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}
