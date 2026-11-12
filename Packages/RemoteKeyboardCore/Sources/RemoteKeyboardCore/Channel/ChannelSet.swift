import CryptoKit
import Foundation

/// The counter channels of one authenticated connection: one sealer and one opener per `CounterChannel.Kind`, each
/// with its own key, counter and replay window. It is created once per connection by `takeChannelSet()` of the
/// handshake reducer and the adapter keeps it until the connection ends; measuring again, switching a measurement
/// mode off and on and entering or leaving a pointer page all use the same sealers, so no key ever sees a counter that
/// starts at 1 twice. The keys never leave this object.
///
/// Not thread-safe: use it only in the adapter's single serial context (the iPhone's main thread, the Mac central's queue).
public final class ChannelSet {
    private let keys: [CounterChannel.Kind: SymmetricKey]
    private let sealers: [CounterChannel.Kind: ChannelSealer]
    private let openers: [CounterChannel.Kind: ChannelOpener]

    init(pairKey: SymmetricKey, hostNonce: Data, phoneNonce: Data, startingCounter: UInt64 = 0) {
        var keys: [CounterChannel.Kind: SymmetricKey] = [:]
        var sealers: [CounterChannel.Kind: ChannelSealer] = [:]
        var openers: [CounterChannel.Kind: ChannelOpener] = [:]
        for kind in CounterChannel.Kind.allCases {
            let key = CounterChannel.deriveKey(kind, pairKey: pairKey, hostNonce: hostNonce, phoneNonce: phoneNonce)
            keys[kind] = key
            sealers[kind] = ChannelSealer(kind: kind, key: key, startingCounter: startingCounter)
            openers[kind] = ChannelOpener(kind: kind, key: key)
        }
        self.keys = keys
        self.sealers = sealers
        self.openers = openers
    }

    /// The same instance every time for one kind.
    public func sealer(_ kind: CounterChannel.Kind) -> ChannelSealer {
        guard let sealer = sealers[kind] else { preconditionFailure("every kind is built in init") }
        return sealer
    }

    /// The same instance every time for one kind.
    public func opener(_ kind: CounterChannel.Kind) -> ChannelOpener {
        guard let opener = openers[kind] else { preconditionFailure("every kind is built in init") }
        return opener
    }

    /// Tests compare keys with each other; nothing outside the module can read one.
    func keyDataForTesting(_ kind: CounterChannel.Kind) -> Data {
        keys[kind].map { $0.withUnsafeBytes { Data($0) } } ?? Data()
    }
}
