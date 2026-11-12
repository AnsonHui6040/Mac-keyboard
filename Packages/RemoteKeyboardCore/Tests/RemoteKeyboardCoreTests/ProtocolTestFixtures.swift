import CryptoKit
import Foundation
@testable import RemoteKeyboardCore

/// Shared identities and reducer builders for the protocol v4 tests. Fixed bytes keep every run deterministic.
enum Fixture {
    static let hostId = Data((0..<16).map { UInt8($0) })
    static let phoneId = Data((16..<32).map { UInt8($0) })
    static let hostIdentity = HostIdentity(id: hostId, name: "書房的 Mac", platform: .mac)
    static let phoneIdentity = PhoneIdentity(id: phoneId, name: "Anson 的 iPhone", platform: .ios)
}

/// A phone-side reducer that has `pairKey` for the host `Fixture.hostId`, or no current host when `pairKey` is nil.
func makePhone(_ pairKey: SymmetricKey?, nonce: Data) -> PhoneHandshake {
    PhoneHandshake(selected: pairKey.map { (hostId: Fixture.hostId, pairKey: $0) }, phoneNonce: nonce)
}

/// A host-side reducer that knows `Fixture.phoneIdentity` with `pairKey`, or no phone at all when `pairKey` is nil.
func makeMac(_ pairKey: SymmetricKey?, nonce: Data, route: MacHandshake.Route = .selected) -> MacHandshake {
    MacHandshake(
        hostId: Fixture.hostId, phones: pairKey.map { [PairedPhone(identity: Fixture.phoneIdentity, pairKey: $0)] } ?? [],
        hostNonce: nonce, route: route)
}

/// `hello` for the fixture host.
func helloMessage(_ nonce: Data) -> ControlMessage { .hello(hostId: Fixture.hostId, hostNonce: nonce) }

extension Pairing {
    /// The key derivation with the fixture identities, for tests that only vary keys.
    static func sharedKey(
        myPrivate: P256.KeyAgreement.PrivateKey, peerPublic: Data, hostPublic: Data, phonePublic: Data
    ) throws -> SymmetricKey {
        try sharedKey(
            myPrivate: myPrivate, peerPublic: peerPublic, hostPublic: hostPublic, phonePublic: phonePublic,
            host: Fixture.hostIdentity, phone: Fixture.phoneIdentity)
    }
}

/// A P-256 key whose private scalar is the small integer `n` (docs/protocol/v4.md uses 1 and 2).
func scalarKey(_ n: UInt8) -> P256.KeyAgreement.PrivateKey {
    var raw = Data(repeating: 0, count: 32)
    raw[31] = n
    return try! P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
}
