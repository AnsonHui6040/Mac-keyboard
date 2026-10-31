#if DEBUG
import Foundation

/// The plaintext of a `0x7E` measurement packet (spec §13.1), 16 bytes, or 157 when zero-padded to the size of a 182-byte
/// packet. It carries no typed text; `dxSixteenths` only moves the M4 test cursor and is never logged.
///
///     [0] kind  [1] reserved 0  [2-3] dx Int16 BE (1/16 pt)  [4-7] seq UInt32 BE  [8-15] phoneTimeMicros UInt64 BE
public struct MeasurePayload: Equatable, Sendable {
    public enum Kind: UInt8, Sendable {
        case burst = 1, rtt = 2, cursor = 3, heartbeat = 4
    }

    public static let shortLength = 16
    public static let paddedLength = 157

    public var kind: Kind
    public var dxSixteenths: Int16
    public var seq: UInt32
    public var phoneTimeMicros: UInt64

    public init(kind: Kind, dxSixteenths: Int16, seq: UInt32, phoneTimeMicros: UInt64) {
        self.kind = kind
        self.dxSixteenths = dxSixteenths
        self.seq = seq
        self.phoneTimeMicros = phoneTimeMicros
    }

    /// - Parameter padTo: 16 or 157; the bytes after the first 16 are zero.
    public func encode(padTo: Int = MeasurePayload.shortLength) -> Data {
        var data = Data(capacity: max(padTo, Self.shortLength))
        data.append(kind.rawValue)
        data.append(0)
        data.append(contentsOf: bigEndian(UInt16(bitPattern: dxSixteenths)))
        data.append(contentsOf: bigEndian(seq))
        data.append(contentsOf: bigEndian(phoneTimeMicros))
        if padTo > data.count { data.append(Data(count: padTo - data.count)) }
        return data
    }

    public static func decode(_ data: Data) -> MeasurePayload? {
        let bytes = [UInt8](data)
        guard bytes.count == shortLength || bytes.count == paddedLength, bytes[1] == 0,
              bytes[shortLength...].allSatisfy({ $0 == 0 }), let kind = Kind(rawValue: bytes[0])
        else { return nil }
        return MeasurePayload(
            kind: kind, dxSixteenths: Int16(bitPattern: UInt16(truncatingIfNeeded: integer(bytes[2..<4]))),
            seq: UInt32(truncatingIfNeeded: integer(bytes[4..<8])), phoneTimeMicros: integer(bytes[8..<16]))
    }
}

/// The Mac's reply to an `rtt` probe (16 bytes): the probe's seq and phone time echoed back, and how long the Mac held it.
///
///     [0-3] seq UInt32 BE  [4-11] phoneTimeMicros UInt64 BE  [12-15] macHoldMicros UInt32 BE
public struct MeasureEchoPayload: Equatable, Sendable {
    public static let length = 16

    public var seq: UInt32
    public var phoneTimeMicros: UInt64
    public var macHoldMicros: UInt32

    public init(seq: UInt32, phoneTimeMicros: UInt64, macHoldMicros: UInt32) {
        self.seq = seq
        self.phoneTimeMicros = phoneTimeMicros
        self.macHoldMicros = macHoldMicros
    }

    public func encode() -> Data {
        Data(bigEndian(seq) + bigEndian(phoneTimeMicros) + bigEndian(macHoldMicros))
    }

    public static func decode(_ data: Data) -> MeasureEchoPayload? {
        let bytes = [UInt8](data)
        guard bytes.count == length else { return nil }
        return MeasureEchoPayload(
            seq: UInt32(truncatingIfNeeded: integer(bytes[0..<4])), phoneTimeMicros: integer(bytes[4..<12]),
            macHoldMicros: UInt32(truncatingIfNeeded: integer(bytes[12..<16])))
    }
}

/// Microseconds from one monotonic clock of this process (it does not count time the machine sleeps). Only differences
/// between two readings on the same device mean anything; the two devices' clocks are never compared.
public enum MeasureClock {
    public static func nowMicros() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }
}

private func bigEndian<T: FixedWidthInteger>(_ value: T) -> [UInt8] {
    (0..<T.bitWidth / 8).map { UInt8(truncatingIfNeeded: value >> (T.bitWidth - 8 - 8 * $0)) }
}

private func integer(_ bytes: ArraySlice<UInt8>) -> UInt64 {
    bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
}
#endif
