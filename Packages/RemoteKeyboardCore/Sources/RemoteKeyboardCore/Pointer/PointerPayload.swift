import Foundation

/// The 16-byte plaintext of a `0x03` pointer packet (trackpad spec §6.2, MVP subset). It travels only inside the counter
/// AEAD envelope of `CounterChannel.Kind.pointer`; nothing here knows about keys or counters.
///
///     [0] opcode  [1] buttons  [2-3] dx  [4-5] dy  [6-7] dt  [8-11] actionId  [12] arg  [13] status  [14-15] buttonSeq
///
/// Everything is big-endian. `dx` and `dy` are in 1/16 of an iPhone point, `dt` in tenths of a millisecond. A bit that must
/// be zero and is not makes the whole packet unreadable (`decode` returns `nil`).
public struct PointerPayload: Equatable, Sendable {
    public static let length = 16

    public enum Opcode: UInt8, Sendable {
        case move = 0x01
        case scroll = 0x02
        case click = 0x10
        case buttonState = 0x11
        case heartbeat = 0x12
    }

    /// The `arg` of a `scroll` packet.
    public enum ScrollPhase: UInt8, Sendable {
        case changed = 0
        case began = 1
        case ended = 2
        case cancelled = 3
    }

    /// `buttons`: bit0 left, bit1 right, bits 4-7 the number of touches (for diagnosis only), bits 2-3 reserved.
    public static let leftButtonBit: UInt8 = 0x01
    private static let reservedButtonBits: UInt8 = 0x0C
    /// `status`: bit0 accumulated while the radio was full, bit1 stale movement dropped, bit2 truncated to the field limit.
    public static let statusAfterBlock: UInt8 = 0x01
    public static let statusTruncated: UInt8 = 0x04
    private static let reservedStatusBits: UInt8 = 0xF8

    public var opcode: Opcode
    public var buttons: UInt8
    public var dx: Int16
    public var dy: Int16
    public var dt: UInt16
    public var actionId: UInt32
    public var arg: UInt8
    public var status: UInt8
    public var buttonSeq: UInt16

    public init(
        opcode: Opcode, buttons: UInt8, dx: Int16, dy: Int16, dt: UInt16, actionId: UInt32 = 0, arg: UInt8 = 0,
        status: UInt8 = 0, buttonSeq: UInt16
    ) {
        self.opcode = opcode
        self.buttons = buttons
        self.dx = dx
        self.dy = dy
        self.dt = dt
        self.actionId = actionId
        self.arg = arg
        self.status = status
        self.buttonSeq = buttonSeq
    }

    public var leftDown: Bool { buttons & Self.leftButtonBit != 0 }

    public var scrollPhase: ScrollPhase? { opcode == .scroll ? ScrollPhase(rawValue: arg) : nil }

    /// The button of a `click` (0 left, 1 right) and its count (1 to 3).
    public var clickButton: Int { Int(arg & 0x03) }
    public var clickCount: Int { Int(arg >> 4) }

    public static func clickArg(button: Int = 0, count: Int) -> UInt8 {
        UInt8(truncatingIfNeeded: (count << 4) | (button & 0x03))
    }

    public func encode() -> Data {
        var bytes = [UInt8](repeating: 0, count: Self.length)
        bytes[0] = opcode.rawValue
        bytes[1] = buttons
        Self.put(UInt16(bitPattern: dx), into: &bytes, at: 2)
        Self.put(UInt16(bitPattern: dy), into: &bytes, at: 4)
        Self.put(dt, into: &bytes, at: 6)
        for index in 0..<4 { bytes[8 + index] = UInt8(truncatingIfNeeded: actionId >> (8 * (3 - UInt32(index)))) }
        bytes[12] = arg
        bytes[13] = status
        Self.put(buttonSeq, into: &bytes, at: 14)
        return Data(bytes)
    }

    public static func decode(_ data: Data) -> PointerPayload? {
        let bytes = [UInt8](data)
        guard bytes.count == length, let opcode = Opcode(rawValue: bytes[0]) else { return nil }
        guard bytes[1] & reservedButtonBits == 0, bytes[13] & reservedStatusBits == 0 else { return nil }
        let arg = bytes[12]
        switch opcode {
        case .scroll:
            guard ScrollPhase(rawValue: arg) != nil else { return nil }
        case .click:
            // Bits 2-3 are reserved, only the left and right button exist, and a count is 1 to 3.
            guard arg & 0x0C == 0, arg & 0x03 <= 1, (1...3).contains(Int(arg >> 4)) else { return nil }
        case .move, .buttonState, .heartbeat:
            break
        }
        let actionId = bytes[8..<12].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return PointerPayload(
            opcode: opcode, buttons: bytes[1], dx: Int16(bitPattern: get(bytes, at: 2)), dy: Int16(bitPattern: get(bytes, at: 4)),
            dt: get(bytes, at: 6), actionId: actionId, arg: arg, status: bytes[13], buttonSeq: get(bytes, at: 14))
    }

    private static func put(_ value: UInt16, into bytes: inout [UInt8], at index: Int) {
        bytes[index] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[index + 1] = UInt8(truncatingIfNeeded: value)
    }

    private static func get(_ bytes: [UInt8], at index: Int) -> UInt16 {
        UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1])
    }
}

/// 16-bit sequence arithmetic (RFC 1982): `a` is newer than `b` when `0 < (a − b) mod 65536 < 32768`.
public func isNewerButtonSeq(_ a: UInt16, than b: UInt16) -> Bool {
    let difference = a &- b
    return difference != 0 && difference < 0x8000
}

/// The monotonic clock the pointer code runs on, in microseconds. It is the same clock as `UITouch.timestamp`.
public enum PointerClock {
    public static func nowMicros() -> UInt64 {
        UInt64(max(0, ProcessInfo.processInfo.systemUptime) * 1_000_000)
    }
}
