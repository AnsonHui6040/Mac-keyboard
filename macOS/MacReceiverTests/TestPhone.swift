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
    /// The service UUIDs of every scan started, oldest first.
    var scans: [[UUID]] = []
    func startScan(services: [UUID]) {
        scans.append(services)
        calls.append(.startScan)
    }
    func stopScan() { calls.append(.stopScan) }
    func connect(_ id: UUID) { calls.append(.connect(id)) }
    func discover(_ id: UUID) { calls.append(.discover(id)) }
    func cancel(_ id: UUID) { calls.append(.cancel(id)) }
    func forget(_ id: UUID) { calls.append(.forget(id)) }
    func writeControl(_ data: Data) -> Bool { controlWrites.append(data); return true }

    var writes: [ControlMessage] { controlWrites.compactMap { try? ControlCodec.decode($0) } }
}

/// Fixed identities for the tests. Fixed bytes keep every run deterministic.
enum TestIdentity {
    static let hostId = Data((0..<16).map { UInt8($0) })
    static let host = HostIdentity(id: hostId, name: "書房的 Mac", platform: .mac)

    /// The nth test phone: its own id and name.
    static func phone(_ n: UInt8 = 1) -> PhoneIdentity {
        PhoneIdentity(id: Data((0..<16).map { $0 == 0 ? n : UInt8(0x20 + $0) }), name: "手機\(n)", platform: .ios)
    }

    static func key(_ n: UInt8) -> SymmetricKey { SymmetricKey(data: Data(repeating: 0x10 &* n &+ 0x01, count: 32)) }
}

/// In-memory pairing store; counts saves so a test can prove nothing was stored.
final class FakePairingStore: PairingStoring {
    private(set) var host: HostIdentity
    private(set) var phones: [PairedPhone]
    private(set) var saves = 0
    private(set) var legacyRemovals = 0
    var failSave = false

    init(host: HostIdentity = TestIdentity.host, phones: [PairedPhone] = []) {
        self.host = host
        self.phones = phones
    }

    func loadHost() -> HostIdentity { host }
    func renameHost(_ name: String) throws -> HostIdentity {
        let trimmed = IdentityName.clamp(name.trimmingCharacters(in: .whitespacesAndNewlines))
        host = HostIdentity(id: host.id, name: trimmed.isEmpty ? "Mac" : trimmed, platform: host.platform)
        return host
    }
    func loadPhones() -> [PairedPhone] { phones }

    func save(_ phone: PairedPhone) throws {
        if failSave { throw PairingStoreError.file("save: errno 5") }
        var list = PairedList(entries: phones)
        if list.add(phone) == .full { throw PairingStoreError.full }
        phones = list.entries
        saves += 1
    }

    func delete(phoneId: Data) { phones.removeAll { $0.identity.id == phoneId } }
    func removeLegacyKey() { legacyRemovals += 1 }
}

/// The iPhone side of the handshake, built from the same Core reducers the keyboard uses.
@MainActor
final class TestPhone {
    var handshake: PhoneHandshake
    let nonce: Data
    let identity: PhoneIdentity
    private var messageId: UInt16 = 0

    /// - Parameters:
    ///   - pairKey: the key shared with the host `hostId`; `nil` for a phone that has no current host.
    ///   - hostId: the host this phone currently types to.
    init(
        pairKey: SymmetricKey?, identity: PhoneIdentity = TestIdentity.phone(), hostId: Data = TestIdentity.hostId,
        nonce: Data = Pairing.randomNonce()
    ) {
        self.nonce = nonce
        self.identity = identity
        handshake = PhoneHandshake(selected: pairKey.map { (hostId: hostId, pairKey: $0) }, phoneNonce: nonce)
    }

    /// One message as the frames a notify would carry.
    func frames(_ message: PeripheralMessage) throws -> [Data] {
        defer { messageId &+= 1 }
        return try FrameCodec.split(try PeripheralCodec.encode(message), messageId: messageId, maxFrameBytes: 182)
    }

    /// Raw bytes as the frames a notify would carry.
    func frames(raw: Data) throws -> [Data] {
        defer { messageId &+= 1 }
        return try FrameCodec.split(raw, messageId: messageId, maxFrameBytes: 182)
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
    let store: FakePairingStore
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
    var lastHostNonce: Data { nonces.last }
    private var consumed = 0

    /// - Parameter pairKey: the key of one paired phone (`TestIdentity.phone()`); `nil` for a Mac with nobody paired.
    convenience init(pairKey: SymmetricKey?, handshakeTimeout: TimeInterval = 5) {
        self.init(
            phones: pairKey.map { [PairedPhone(identity: TestIdentity.phone(), pairKey: $0)] } ?? [],
            handshakeTimeout: handshakeTimeout)
    }

    init(phones: [PairedPhone], handshakeTimeout: TimeInterval = 5) {
        let name = "rk.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let driver = driver
        let clock = clock
        central = ReceiverBLECentral(
            hostId: TestIdentity.hostId, defaults: defaults, clock: { clock.now },
            uptime: { clock.now.timeIntervalSince1970 }, makeDriver: { _ in driver })
        store = FakePairingStore(phones: phones)
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

    /// Arms receiving and brings the link to ready, which starts the handshake on the Mac. `route` is how the peripheral was
    /// found: its advertisement carried the selected UUID or the pairing UUID.
    func connect(route: MacHandshake.Route = .selected) {
        if !central.isArmed { central.startReceiving() }
        central.handleLink(.power(.poweredOn))
        central.handleLink(.discovered(peripheral), route: route)
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

    private var answered = 0

    /// Plays CoreBluetooth's write responses for every control write made so far (the recording radio never answers by
    /// itself, so a test decides when a response arrives).
    func answerOutstandingWrites() {
        while answered < driver.controlWrites.count {
            answered += 1
            central.controlWriteCompleted()
        }
    }

    var cancels: [UUID] {
        driver.calls.compactMap { if case .cancel(let id) = $0 { id } else { nil } }
    }
}
