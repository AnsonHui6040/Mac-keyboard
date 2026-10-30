import CryptoKit
import Foundation
import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

/// Records the radio calls of a `ReceiverBLECentral` and the control writes it makes.
@MainActor
final class RecordingDriver: CentralDriving {
    enum Call: Equatable { case startScan, stopScan, connect(UUID), discover(UUID), cancel(UUID), forget(UUID) }
    var calls: [Call] = []
    var controlWrites: [Data] = []
    func startScan() { calls.append(.startScan) }
    func stopScan() { calls.append(.stopScan) }
    func connect(_ id: UUID) { calls.append(.connect(id)) }
    func discover(_ id: UUID) { calls.append(.discover(id)) }
    func cancel(_ id: UUID) { calls.append(.cancel(id)) }
    func forget(_ id: UUID) { calls.append(.forget(id)) }
    func writeControl(_ data: Data) { controlWrites.append(data) }

    var writes: [ControlMessage] { controlWrites.compactMap { try? ControlCodec.decode($0) } }
}

/// In-memory pair key store; counts saves so a test can prove nothing was stored.
final class FakePairKeyStore: PairKeyStoring {
    private(set) var key: SymmetricKey?
    private(set) var saves = 0
    var failSave = false
    init(key: SymmetricKey? = nil) { self.key = key }
    func load() -> SymmetricKey? { key }
    func save(_ key: SymmetricKey) throws {
        if failSave { throw CocoaError(.fileWriteUnknown) }
        saves += 1
        self.key = key
    }
    func delete() { key = nil }
}

/// The iPhone side of the handshake, built from the same Core reducers the keyboard uses.
@MainActor
final class TestPhone {
    var handshake: PhoneHandshake
    let nonce: Data
    private var messageId: UInt16 = 0

    init(pairKey: SymmetricKey?, nonce: Data = Pairing.randomNonce()) {
        self.nonce = nonce
        handshake = PhoneHandshake(pairKey: pairKey, phoneNonce: nonce)
    }

    /// One message as the frames a notify would carry.
    func frames(_ message: PeripheralMessage) throws -> [Data] {
        defer { messageId &+= 1 }
        return try FrameCodec.split(try PeripheralCodec.encode(message), messageId: messageId, maxFrameBytes: 182)
    }

    func receive(_ controlWrite: Data) -> PhoneHandshakeOutput {
        guard let message = try? ControlCodec.decode(controlWrite) else { return .failed }
        return handshake.receive(message)
    }

    func sealed(_ kind: EventKind, session: UUID, seq: UInt64 = 1, epoch: UInt64? = 3, id: UUID = UUID()) throws -> PeripheralMessage {
        let event = KeyboardEvent(
            protocolVersion: KeyboardEvent.currentVersion, eventId: id, sessionId: session, seq: seq, focusEpoch: epoch, kind: kind)
        return try handshake.sealEvent(event)
    }
}

final class NonceBox {
    var last = Data()
}

final class TestClock {
    var now = Date(timeIntervalSince1970: 10_000)
}

/// A `ReceiverBLECentral` and `ReceiverSecurity` on a recording radio, plus a way to play an iPhone against them.
@MainActor
final class SecurityRig {
    let driver = RecordingDriver()
    let store: FakePairKeyStore
    let central: ReceiverBLECentral
    let security: ReceiverSecurity
    let peripheral = UUID()
    private let clock = TestClock()
    var now: Date {
        get { clock.now }
        set { clock.now = newValue }
    }
    private(set) var events: [KeyboardEvent] = []
    private(set) var malformed = 0
    private(set) var authenticatedCount = 0
    private(set) var linkLostCount = 0
    private let nonces = NonceBox()
    /// The nonce the Mac used for its most recent `hello`.
    var lastMacNonce: Data { nonces.last }
    private var consumed = 0

    init(pairKey: SymmetricKey?, handshakeTimeout: TimeInterval = 5) {
        let name = "rk.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let driver = driver
        let clock = clock
        central = ReceiverBLECentral(defaults: defaults, clock: { clock.now }, makeDriver: { _ in driver })
        store = FakePairKeyStore(key: pairKey)
        security = ReceiverSecurity(
            central: central, store: store, clock: { clock.now },
            makeNonce: { [nonces] in
                nonces.last = Pairing.randomNonce()
                return nonces.last
            },
            handshakeTimeout: handshakeTimeout)
        security.onEvent = { [unowned self] in events.append($0) }
        security.onMalformed = { [unowned self] in malformed += 1 }
        security.onAuthenticated = { [unowned self] in authenticatedCount += 1 }
        security.onLinkLost = { [unowned self] in linkLostCount += 1 }
        security.refreshPairedState()
    }

    /// Arms receiving and brings the link to ready, which starts the handshake on the Mac.
    func connect() {
        if !central.isArmed { central.startReceiving() }
        central.handleLink(.power(.poweredOn))
        central.handleLink(.discovered(peripheral))
        central.handleLink(.connected(peripheral))
        central.handleLink(.linkReady(peripheral))
    }

    /// Control messages written since the last call.
    func newWrites() -> [ControlMessage] {
        let all = driver.writes
        defer { consumed = all.count }
        return Array(all.dropFirst(consumed))
    }

    func deliver(_ message: PeripheralMessage, from phone: TestPhone) throws {
        for frame in try phone.frames(message) { central.receive(eventData: frame) }
    }

    /// Plays the whole handshake: the Mac's `hello`, the phone's `helloReply`, the Mac's `auth`.
    @discardableResult
    func authenticate(_ phone: TestPhone) throws -> [PhoneHandshakeOutput] {
        var outputs: [PhoneHandshakeOutput] = []
        let hello = try XCTUnwrap(newWrites().first, "the Mac must open with hello")
        guard case .send(let reply) = phone.handshake.receive(hello) else {
            XCTFail("the phone did not answer hello")
            return outputs
        }
        try deliver(reply, from: phone)
        for message in newWrites() { outputs.append(phone.handshake.receive(message)) }
        return outputs
    }

    func bytesWritten() -> Int { driver.controlWrites.count }

    var cancels: [UUID] {
        driver.calls.compactMap { if case .cancel(let id) = $0 { id } else { nil } }
    }
}
