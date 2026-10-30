import CoreGraphics
import CryptoKit
import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

final class FocusTransitionTests: XCTestCase {
    private func snap(_ editable: Bool, epoch: UInt64, app: String? = "TextEdit", trusted: Bool = true) -> FocusSnapshot {
        FocusSnapshot(axTrusted: trusted, frontmostPID: 1, appName: app, editable: editable, epoch: epoch)
    }

    func testGainedEditableOnFirstEditableSnapshot() {
        XCTAssertTrue(FocusTransition.gainedEditable(previous: nil, next: snap(true, epoch: 1)))
        XCTAssertFalse(FocusTransition.gainedEditable(previous: nil, next: snap(false, epoch: 1)))
    }

    func testGainedEditableWhenPreviousWasNotEditable() {
        XCTAssertTrue(FocusTransition.gainedEditable(previous: snap(false, epoch: 3), next: snap(true, epoch: 3)))
    }

    func testGainedEditableWhenEpochChangedWhileEditable() {
        XCTAssertTrue(FocusTransition.gainedEditable(previous: snap(true, epoch: 3), next: snap(true, epoch: 4)))
    }

    func testNoGainWhenStillTheSameEditableField() {
        XCTAssertFalse(FocusTransition.gainedEditable(previous: snap(true, epoch: 3), next: snap(true, epoch: 3, app: "Renamed")))
    }

    func testNoGainWhenNextIsNotEditable() {
        XCTAssertFalse(FocusTransition.gainedEditable(previous: snap(true, epoch: 3), next: snap(false, epoch: 4)))
    }

    func testStatusCarriesAccessibilityTrustAndIsNeverReadyWithout() {
        let untrusted = FocusTransition.status(for: snap(true, epoch: 3, trusted: false))
        XCTAssertFalse(untrusted.trusted)
        XCTAssertFalse(untrusted.ready)
        let trusted = FocusTransition.status(for: snap(true, epoch: 3))
        XCTAssertTrue(trusted.trusted)
        XCTAssertTrue(trusted.ready)
    }

    func testStatusChangesOnEpochEditableAppOrTrust() {
        let base = snap(true, epoch: 3)
        XCTAssertTrue(FocusTransition.statusChanged(previous: nil, next: base))
        XCTAssertTrue(FocusTransition.statusChanged(previous: base, next: snap(true, epoch: 4)))
        XCTAssertTrue(FocusTransition.statusChanged(previous: base, next: snap(false, epoch: 3)))
        XCTAssertTrue(FocusTransition.statusChanged(previous: base, next: snap(true, epoch: 3, app: "Notes")))
        XCTAssertTrue(FocusTransition.statusChanged(previous: base, next: snap(true, epoch: 3, trusted: false)))
        XCTAssertFalse(FocusTransition.statusChanged(previous: base, next: snap(true, epoch: 3)))
    }

    func testStatusReadyNeedsTrustAndEditable() {
        XCTAssertTrue(FocusTransition.status(for: snap(true, epoch: 7)).ready)
        XCTAssertFalse(FocusTransition.status(for: snap(false, epoch: 7)).ready)
        XCTAssertFalse(FocusTransition.status(for: snap(true, epoch: 7, trusted: false)).ready)
        XCTAssertEqual(FocusTransition.status(for: snap(true, epoch: 7)).focusEpoch, 7)
    }

    func testLongAppNamesAreCut() {
        let long = String(repeating: "名", count: 100)
        XCTAssertEqual(FocusTransition.status(for: snap(true, epoch: 1, app: long)).appName?.count, FocusTransition.maxAppNameLength)
        XCTAssertNil(FocusTransition.status(for: snap(true, epoch: 1, app: nil)).appName)
    }
}

/// The coordinator against a real `ReceiverBLECentral` with a fake radio, a real `ReceiverSecurity` with a paired fake
/// iPhone, and a real `EventPipeline` with fake input. Nothing here touches Bluetooth, Accessibility, the Keychain or
/// the real input stream.
@MainActor
final class ReceiverCoordinatorWiringTests: XCTestCase {
    @MainActor private final class CountingPoster: EventPosting {
        var batches = 0
        func post(_ events: [CGEvent]) { batches += 1 }
    }

    @MainActor private final class AsciiController: InputSourceControlling {
        func currentID() -> String { InputSourceSwitcher.asciiID }
        func select(_ id: String) -> Bool { true }
    }

    @MainActor private final class Rig {
        let coordinator: ReceiverCoordinator
        let central: ReceiverBLECentral
        let security: ReceiverSecurity
        let focus: FocusMonitor
        let driver = RecordingDriver()
        let poster = CountingPoster()
        let phone: TestPhone
        let pairKey: SymmetricKey
        let peripheral = UUID()
        let session = UUID()
        private var consumed = 0
        private(set) var delivered: [ControlMessage] = []
        private var messageSeq: UInt64 = 0

        init(pairKey: SymmetricKey) {
            self.pairKey = pairKey
            let name = "rk.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            let driver = driver
            central = ReceiverBLECentral(defaults: defaults, makeDriver: { _ in driver })
            security = ReceiverSecurity(central: central, store: FakePairKeyStore(key: pairKey))
            focus = FocusMonitor()
            let poster = poster
            let current = ReceiverCoordinatorWiringTests.editable(epoch: 3)
            let security = security
            let pipeline = EventPipeline(
                snapshot: { current },
                switcher: InputSourceSwitcher(controller: AsciiController(), composition: nil, settle: { _ in }),
                injector: TextInjector(poster: poster),
                sendAck: { [weak security] ack in security?.send(.ack(ack)) },
                noteValidEvent: { [weak central] in central?.noteEvent() }
            )
            coordinator = ReceiverCoordinator(focus: focus, central: central, security: security, pipeline: pipeline)
            phone = TestPhone(pairKey: pairKey)
            coordinator.start()
        }

        /// Reads what the Mac wrote since the last call as the iPhone would: plain handshake messages drive the phone
        /// reducer, sealed ones are opened and collected in `delivered`.
        func pump() throws {
            while consumed < driver.controlWrites.count {
                let data = driver.controlWrites[consumed]
                consumed += 1
                switch phone.receive(data) {
                case .send(let reply):
                    for frame in try phone.frames(reply) { central.receive(eventData: frame) }
                case .deliver(let message):
                    delivered.append(message)
                case .authenticated, .none, .failed:
                    break
                }
            }
        }

        var acks: [Ack] { delivered.compactMap { if case .ack(let ack) = $0 { ack } else { nil } } }
        var statuses: [ReceiverStatus] { delivered.compactMap { if case .status(let status) = $0 { status } else { nil } } }

        func deliver(_ kind: EventKind, id: UUID = UUID(), seq: UInt64? = nil) throws -> UUID {
            messageSeq += 1
            let message = try phone.sealed(kind, session: session, seq: seq ?? messageSeq, epoch: 3, id: id)
            for frame in try phone.frames(message) { central.receive(eventData: frame) }
            return id
        }
    }

    private func rig() -> Rig { Rig(pairKey: SymmetricKey(data: Data(repeating: 0x33, count: 32))) }

    private static func editable(epoch: UInt64) -> FocusSnapshot {
        FocusSnapshot(axTrusted: true, frontmostPID: 42, appName: "TextEdit", editable: true, epoch: epoch)
    }

    private func bringLinkUp(_ r: Rig) throws {
        r.central.handleLink(.power(.poweredOn))
        r.central.handleLink(.discovered(r.peripheral))
        r.central.handleLink(.connected(r.peripheral))
        r.central.handleLink(.linkReady(r.peripheral))
        try r.pump()
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testCoordinatorArmsOnEditableFocusAndForwardsEvents() async throws {
        let r = rig()
        XCTAssertFalse(r.central.isArmed)

        r.focus.onChange?(FocusSnapshot(axTrusted: true, frontmostPID: 42, appName: "Finder", editable: false, epoch: 2))
        XCTAssertFalse(r.central.isArmed, "a non-editable focus does not arm the Receiver")

        r.focus.onChange?(Self.editable(epoch: 3))
        XCTAssertTrue(r.central.isArmed, "clicking an editable field arms receiving")

        try bringLinkUp(r)
        XCTAssertEqual(r.delivered, [.status(ReceiverStatus(ready: true, appName: "TextEdit", focusEpoch: 3))],
                       "the first status is written once the phone is authenticated, and it is sealed")

        let id = try r.deliver(.text("A"))
        await waitUntil { try? r.pump(); return !r.acks.isEmpty }
        XCTAssertEqual(r.acks, [Ack(eventId: id, result: .posted)])
        XCTAssertEqual(r.poster.batches, 1)
    }

    func testNoStatusIsWrittenBeforeThePhoneAuthenticates() throws {
        let r = rig()
        r.focus.onChange?(Self.editable(epoch: 3))
        r.central.handleLink(.power(.poweredOn))
        r.central.handleLink(.discovered(r.peripheral))
        r.central.handleLink(.connected(r.peripheral))
        r.central.handleLink(.linkReady(r.peripheral))
        XCTAssertEqual(r.driver.writes.count, 1, "only hello")
        r.coordinator.sendStatus()
        XCTAssertEqual(r.driver.writes.count, 1, "a status changed by focus before auth is not written")
    }

    func testPingReachesThePipelineAndIsAckedPong() async throws {
        let r = rig()
        r.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(r)
        let id = try r.deliver(.ping(shownAtMs: 1, connectedAtMs: 2))
        await waitUntil { try? r.pump(); return !r.acks.isEmpty }
        XCTAssertEqual(r.acks, [Ack(eventId: id, result: .pong)])
        XCTAssertEqual(r.poster.batches, 0)
    }

    func testLinkLossDropsQueuedEventsButKeepsTheDeduplicator() async throws {
        let r = rig()
        r.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(r)

        let id = try r.deliver(.text("A"), seq: 1)
        await waitUntil { try? r.pump(); return r.acks.count == 1 }
        XCTAssertEqual(r.poster.batches, 1)

        // Queued behind nothing yet read: the link drops before the consumer runs, so they are never typed.
        _ = try r.deliver(.text("B"), seq: 2)
        r.central.handleLink(.disconnected(r.peripheral))
        try bringLinkUpAgain(r)
        try await Task.sleep(for: .milliseconds(100))
        try r.pump()
        XCTAssertEqual(r.acks.count, 1, "the event queued before the link loss is dropped, not typed later")
        XCTAssertEqual(r.poster.batches, 1)

        // The same event again after the reconnect is recognised: acked with the original code, not typed twice.
        _ = try r.deliver(.text("A"), id: id, seq: 1)
        await waitUntil { try? r.pump(); return r.acks.count == 2 }
        XCTAssertEqual(r.acks.last, Ack(eventId: id, result: .posted))
        XCTAssertEqual(r.poster.batches, 1)
    }

    /// After a link loss the same phone comes back: a new connection, so a new handshake and a new session key.
    private func bringLinkUpAgain(_ r: Rig) throws {
        r.central.handleLink(.rescanTimer)
        r.central.handleLink(.discovered(r.peripheral))
        r.central.handleLink(.connected(r.peripheral))
        r.central.handleLink(.linkReady(r.peripheral))
        r.phone.handshake = PhoneHandshake(pairKey: r.pairKey, phoneNonce: Pairing.randomNonce())
        try r.pump()
    }
}
