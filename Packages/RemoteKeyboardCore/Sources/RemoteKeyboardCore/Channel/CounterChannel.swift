import CryptoKit
import Foundation

public enum ChannelError: Error, Equatable, Sendable {
    /// The plaintext length is not one this kind carries.
    case badLength
    /// The counter reached `UInt64.max`; the channel is finished.
    case counterExhausted
    case sealFailed
}

public enum ChannelOpenError: Error, Equatable, Sendable {
    case badMagic, badLength
    /// The counter was seen before (or is 0).
    case replayed
    /// The counter is more than 64 below the largest one accepted.
    case tooOld
    case authFailed
}

/// The counter-AEAD envelope that `0x03` pointer packets and (Debug builds only) `0x7E` measurement packets share (spec §6.1):
///
///     [0] magic  [1-8] counter (UInt64 BE, from 1)  [9 … N−17] ChaCha20 ciphertext  [N−16 … N−1] Poly1305 tag
///
/// The key comes from the pair key and both handshake nonces, with its own HKDF info per kind, so it never equals a
/// session key. The nonce is a 4-byte prefix per kind followed by the counter, and bytes 0–8 are the associated data.
/// Nothing here reads a clock or a random source, and no key leaves `ChannelSet`.
public enum CounterChannel {
    /// `FrameCodec` frames start with this byte; it is not a counter packet.
    public static let frameMagic: UInt8 = 0x02
    #if DEBUG
    public static let measureMagic: UInt8 = 0x7E
    #endif

    static let headerLength = 9
    static let tagLength = 16

    public enum Kind: Hashable, Sendable, CaseIterable {
        case pointer
        #if DEBUG
        /// Measurement probes, iPhone to Mac (notify).
        case measureP2M
        /// Measurement replies, Mac to iPhone (control write).
        case measureM2P
        #endif

        public var magic: UInt8 {
            switch self {
            case .pointer: 0x03
            #if DEBUG
            case .measureP2M, .measureM2P: CounterChannel.measureMagic
            #endif
            }
        }

        var info: String {
            switch self {
            case .pointer: "rk-pointer-p2m"
            #if DEBUG
            case .measureP2M: "rk-measure-p2m"
            case .measureM2P: "rk-measure-m2p"
            #endif
            }
        }

        var noncePrefix: [UInt8] {
            switch self {
            case .pointer: Array("PTR3".utf8)
            #if DEBUG
            case .measureP2M: Array("MSR3".utf8)
            case .measureM2P: Array("MSE3".utf8)
            #endif
            }
        }

        /// Plaintext lengths of this kind: 16 for a pointer packet, 16 or 157 for a measurement probe, 24 for a measurement reply.
        var plaintextLengths: Set<Int> {
            switch self {
            case .pointer: [16]
            #if DEBUG
            case .measureP2M: [16, 157]
            case .measureM2P: [24]
            #endif
            }
        }
    }

    static func deriveKey(_ kind: Kind, pairKey: SymmetricKey, macNonce: Data, phoneNonce: Data) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: pairKey, salt: Data(), info: Data(kind.info.utf8) + macNonce + phoneNonce, outputByteCount: 32)
    }

    static func counterBytes(_ counter: UInt64) -> [UInt8] {
        (0..<8).map { UInt8(truncatingIfNeeded: counter >> (8 * (7 - $0))) }
    }

    static func nonce(_ kind: Kind, counter: UInt64) -> ChaChaPoly.Nonce? {
        try? ChaChaPoly.Nonce(data: Data(kind.noncePrefix + counterBytes(counter)))
    }
}

/// Seals the packets of one kind on one connection. The counter is handed out inside `seal`, so a ciphertext that is
/// discarded (the radio refused it) leaves a gap and is never reused: the next call encrypts with the next counter.
/// Only for the single serial context of the adapter that owns the `ChannelSet`; no lock.
public final class ChannelSealer {
    private let kind: CounterChannel.Kind
    private let key: SymmetricKey
    public private(set) var lastCounter: UInt64

    init(kind: CounterChannel.Kind, key: SymmetricKey, startingCounter: UInt64) {
        self.kind = kind
        self.key = key
        lastCounter = startingCounter
    }

    public func seal(_ plaintext: Data) throws -> Data {
        guard kind.plaintextLengths.contains(plaintext.count) else { throw ChannelError.badLength }
        guard lastCounter < UInt64.max else { throw ChannelError.counterExhausted }
        lastCounter += 1
        let header = Data([kind.magic] + CounterChannel.counterBytes(lastCounter))
        guard let nonce = CounterChannel.nonce(kind, counter: lastCounter),
              let box = try? ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: header)
        else { throw ChannelError.sealFailed }
        return header + box.ciphertext + box.tag
    }
}

/// Opens the packets of one kind on one connection. The replay window is only updated by a packet whose tag verified.
/// Only for the single serial context of the adapter that owns the `ChannelSet`; no lock.
public final class ChannelOpener {
    private let kind: CounterChannel.Kind
    private let key: SymmetricKey
    private var window = ReplayWindow()
    /// The counter of the packet `open` accepted last; 0 before the first.
    public private(set) var lastOpenedCounter: UInt64 = 0

    init(kind: CounterChannel.Kind, key: SymmetricKey) {
        self.kind = kind
        self.key = key
    }

    public func open(_ packet: Data) -> Result<Data, ChannelOpenError> {
        let bytes = [UInt8](packet)
        let lengths = Set(kind.plaintextLengths.map { $0 + CounterChannel.headerLength + CounterChannel.tagLength })
        guard lengths.contains(bytes.count) else { return .failure(.badLength) }
        guard bytes[0] == kind.magic else { return .failure(.badMagic) }
        let counter = bytes[1..<CounterChannel.headerLength].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        switch window.verdict(counter) {
        case .accept: break
        case .replayed: return .failure(.replayed)
        case .tooOld: return .failure(.tooOld)
        }
        let tagStart = bytes.count - CounterChannel.tagLength
        guard let nonce = CounterChannel.nonce(kind, counter: counter),
              let box = try? ChaChaPoly.SealedBox(
                nonce: nonce, ciphertext: Data(bytes[CounterChannel.headerLength..<tagStart]), tag: Data(bytes[tagStart...])),
              let plain = try? ChaChaPoly.open(box, using: key, authenticating: Data(bytes[0..<CounterChannel.headerLength]))
        else { return .failure(.authFailed) }
        window.commit(counter)
        lastOpenedCounter = counter
        return .success(plain)
    }
}
