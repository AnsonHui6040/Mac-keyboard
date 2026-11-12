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

    func testStatusNeverCarriesMeasureByDefault() {
        XCTAssertFalse(FocusTransition.status(for: snap(true, epoch: 3)).measure)
    }

    #if DEBUG
    func testStatusCarriesTheMeasureFlag() {
        XCTAssertTrue(FocusTransition.status(for: snap(true, epoch: 3), measure: true).measure)
    }
    #endif

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

        let pointer: PointerReceiver?
        let pointerOutput = PointerOutputSpy()

        init(pairKey: SymmetricKey, withPointer: Bool = false) {
            self.pairKey = pairKey
            let name = "rk.tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            let driver = driver
            central = ReceiverBLECentral(hostId: TestIdentity.hostId, defaults: defaults, makeDriver: { _ in driver })
            security = ReceiverSecurity(
                central: central,
                store: FakePairingStore(phones: [PairedPhone(identity: TestIdentity.phone(), pairKey: pairKey)]))
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
            let suite = "rk.tests.\(UUID().uuidString)"
            let pointerDefaults = UserDefaults(suiteName: suite)!
            pointerDefaults.removePersistentDomain(forName: suite)
            pointer = withPointer ? PointerReceiver(defaults: pointerDefaults, output: pointerOutput, log: { _ in }) : nil
            coordinator = ReceiverCoordinator(
                focus: focus, central: central, security: security, pipeline: pipeline, pointer: pointer)
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

    private func pointerRig() -> Rig { Rig(pairKey: SymmetricKey(data: Data(repeating: 0x33, count: 32)), withPointer: true) }

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

    func testInputBlockedTurningOnWithNoFocusChangeReachesThePhone() throws {
        let r = rig()
        r.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(r)
        XCTAssertEqual(r.statuses.last?.inputBlocked, false)
        let before = r.statuses.count
        r.focus.onChange?(FocusSnapshot(
            axTrusted: true, frontmostPID: 42, appName: "TextEdit", editable: false, epoch: 3, inputBlocked: true))
        try r.pump()
        XCTAssertEqual(r.statuses.count, before + 1)
        XCTAssertEqual(r.statuses.last?.inputBlocked, true)
        XCTAssertEqual(r.statuses.last?.ready, false)
        r.focus.onChange?(Self.editable(epoch: 3))
        try r.pump()
        XCTAssertEqual(r.statuses.last?.inputBlocked, false)
        XCTAssertEqual(r.statuses.last?.ready, true)
    }

    #if DEBUG
    func testStatusCarriesMeasureModeOnlyWhileItIsOn() throws {
        let r = rig()
        var measure = false
        r.coordinator.measureMode = { measure }
        r.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(r)
        XCTAssertEqual(r.statuses.last?.measure, false)
        measure = true
        r.coordinator.sendStatus()
        try r.pump()
        XCTAssertEqual(r.statuses.last?.measure, true)
        measure = false
        r.coordinator.sendStatus()
        try r.pump()
        XCTAssertEqual(r.statuses.last?.measure, false)
    }

    func testMeasureTextObserverSeesATextWhenItArrivesAndOnlyTexts() async throws {
        let r = rig()
        var seen: [Int] = []
        r.coordinator.measureTextArrived = { seen.append($0.utf8.count) }
        r.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(r)
        _ = try r.deliver(.text(MeasureLongText.text))
        _ = try r.deliver(.backspace)
        await waitUntil { try? r.pump(); return r.acks.count >= 2 }
        XCTAssertEqual(seen, [6_000])
        XCTAssertEqual(r.acks.count, 2, "the pipeline still handles both events")
    }
    #endif

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

    func testFocusPollingFollowsTheAuthenticatedLink() throws {
        let r = rig()
        XCTAssertFalse(r.focus.isLinkActive)
        r.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(r)
        XCTAssertTrue(r.focus.isLinkActive, "authenticated: fast polling")
        r.central.handleLink(.disconnected(r.peripheral))
        XCTAssertFalse(r.focus.isLinkActive, "link lost: slow polling")
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

    // MARK: Touchpad (pointer) wiring

    func testStatusCarriesThePointerGrantOnlyWhenThePointerIsWiredAndOn() throws {
        let plain = rig()
        plain.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(plain)
        XCTAssertNil(plain.statuses.last?.pointerGrant)

        let r = pointerRig()
        r.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(r)
        let grant = try XCTUnwrap(r.statuses.last?.pointerGrant, "the first sealed status already carries the grant")
        XCTAssertEqual(r.pointer?.grant, grant)

        r.pointer?.setEnabled(false)
        try r.pump()
        XCTAssertNil(r.statuses.last?.pointerGrant, "turning the switch off tells the keyboard at once")
        r.pointer?.setEnabled(true)
        try r.pump()
        let again = try XCTUnwrap(r.statuses.last?.pointerGrant)
        XCTAssertNotEqual(again, grant)
    }

    func testThePointerGrantReachesThePhoneEvenBeforeAnyFocusSnapshot() throws {
        let r = pointerRig()
        r.central.startReceiving()
        try bringLinkUp(r)
        let grant = try XCTUnwrap(r.statuses.last?.pointerGrant, "a not-ready status carries the grant right after authentication")
        XCTAssertEqual(r.statuses.last?.ready, false)
        XCTAssertEqual(r.pointer?.grant, grant)
        let count = r.statuses.count
        r.pointer?.setEnabled(false)
        try r.pump()
        XCTAssertEqual(r.statuses.count, count + 1)
        XCTAssertNil(r.statuses.last?.pointerGrant)
        r.pointer?.setEnabled(true)
        try r.pump()
        XCTAssertNotNil(r.statuses.last?.pointerGrant)
        XCTAssertNotEqual(r.statuses.last?.pointerGrant, grant)

        let plain = rig()
        plain.central.startReceiving()
        try bringLinkUp(plain)
        XCTAssertTrue(plain.statuses.isEmpty, "without the touchpad and without focus nothing is sent, as before")
    }

    func testPointerOpenIsAnsweredAtOnceWithoutTheTypingPipeline() throws {
        let r = pointerRig()
        r.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(r)
        let grant = try XCTUnwrap(r.pointer?.grant)
        let id = try r.deliver(.pointerOpen(grant: grant))
        try r.pump()
        XCTAssertEqual(r.acks, [Ack(eventId: id, result: .posted)], "answered synchronously, no waiting for the consumer task")
        XCTAssertEqual(r.pointer?.isOpen, true)
        XCTAssertEqual(r.poster.batches, 0)

        let closeId = try r.deliver(.pointerClose)
        try r.pump()
        XCTAssertEqual(r.acks.last, Ack(eventId: closeId, result: .posted))
        XCTAssertEqual(r.pointer?.isOpen, false)
    }

    func testPointerOpenWithAWrongGrantIsRefused() throws {
        let r = pointerRig()
        r.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(r)
        let id = try r.deliver(.pointerOpen(grant: (r.pointer?.grant ?? 0) &+ 1))
        try r.pump()
        XCTAssertEqual(r.acks, [Ack(eventId: id, result: .notAuthorized)])
        XCTAssertEqual(r.pointer?.isOpen, false)
    }

    func testPointerOpenWithoutAPointerReceiverIsRefused() throws {
        let r = rig()
        r.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(r)
        let id = try r.deliver(.pointerOpen(grant: 5))
        try r.pump()
        XCTAssertEqual(r.acks, [Ack(eventId: id, result: .notAuthorized)])
    }

    func testALostLinkClosesThePointerChannel() throws {
        let r = pointerRig()
        r.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(r)
        _ = try r.deliver(.pointerOpen(grant: try XCTUnwrap(r.pointer?.grant)))
        XCTAssertEqual(r.pointer?.isOpen, true)
        r.central.handleLink(.disconnected(r.peripheral))
        XCTAssertEqual(r.pointer?.isOpen, false)
        XCTAssertNil(r.pointer?.grant)
    }

    /// After a link loss the same phone comes back: a new connection, so a new handshake and a new session key.
    private func bringLinkUpAgain(_ r: Rig) throws {
        r.central.handleLink(.rescanTimer)
        r.central.handleLink(.discovered(r.peripheral))
        r.central.handleLink(.connected(r.peripheral))
        r.central.handleLink(.linkReady(r.peripheral))
        r.phone.handshake = PhoneHandshake(
            selected: (hostId: TestIdentity.hostId, pairKey: r.pairKey), phoneNonce: Pairing.randomNonce())
        try r.pump()
    }
}
