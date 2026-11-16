import CoreGraphics
import CryptoKit
import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

final class FocusTransitionTests: XCTestCase {
    private func snap(_ editable: Bool, epoch: UInt64, app: String? = "TextEdit", trusted: Bool = true) -> FocusSnapshot {
        FocusSnapshot(axTrusted: trusted, frontmostPID: 1, appName: app, editable: editable, epoch: epoch)
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
final class LogBox {
    var lines: [String] = []
}

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
        let wifi: WifiProbeLink?
        let wifiTransport = FakeWifiTransport()
        let wifiTimers = ManualWifiTimers()
        let wifiLog = LogBox()
        private var cachedPhoneChannels: ChannelSet?

        init(pairKey: SymmetricKey, withPointer: Bool = false, withWifi: Bool = false, receiving: Bool = true) {
            self.pairKey = pairKey
            let driver = driver
            central = ReceiverBLECentral(hostId: TestIdentity.hostId, makeDriver: { _ in driver })
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
                sendAck: { [weak security] ack in security?.send(.ack(ack)) }
            )
            let suite = "rk.tests.\(UUID().uuidString)"
            let pointerDefaults = UserDefaults(suiteName: suite)!
            pointerDefaults.removePersistentDomain(forName: suite)
            pointer = withPointer ? PointerReceiver(defaults: pointerDefaults, output: pointerOutput, log: { _ in }) : nil
            let timers = wifiTimers
            let wifiLog = wifiLog
            wifi = withWifi
                ? WifiProbeLink(transport: wifiTransport, makeTimer: { timers.make($0, $1) }, log: { wifiLog.lines.append($0) })
                : nil
            coordinator = ReceiverCoordinator(
                focus: focus, central: central, security: security, pipeline: pipeline, pointer: pointer, wifi: wifi)
            // The app routes every `0x03` notification to the touchpad the same way (MacReceiverApp).
            central.pointerHandler = { [weak pointer] in pointer?.handle($0) }
            phone = TestPhone(pairKey: pairKey)
            coordinator.start()
            if receiving { central.startReceiving() }
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

        /// The phone's channel sets of this connection (taken once; a new connection needs a new Rig step).
        func phoneChannels() throws -> ChannelSet {
            if let cachedPhoneChannels { return cachedPhoneChannels }
            let channels = try XCTUnwrap(phone.handshake.takeChannelSet(), "the phone is authenticated")
            cachedPhoneChannels = channels
            return channels
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

    private func rig(receiving: Bool = true) -> Rig {
        Rig(pairKey: SymmetricKey(data: Data(repeating: 0x33, count: 32)), receiving: receiving)
    }

    private func pointerRig() -> Rig { Rig(pairKey: SymmetricKey(data: Data(repeating: 0x33, count: 32)), withPointer: true) }

    private func wifiRig() -> Rig {
        Rig(pairKey: SymmetricKey(data: Data(repeating: 0x33, count: 32)), withPointer: true, withWifi: true)
    }

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

    func testFocusOnEditableFieldDoesNotChangeReceiving() {
        let paused = rig(receiving: false)
        XCTAssertFalse(paused.central.isArmed)
        paused.focus.onChange?(Self.editable(epoch: 3))
        XCTAssertFalse(paused.central.isArmed, "a paused Receiver stays paused when a field gets focus")

        let receiving = rig()
        receiving.focus.onChange?(FocusSnapshot(axTrusted: true, frontmostPID: 42, appName: "Finder", editable: false, epoch: 2))
        receiving.focus.onChange?(Self.editable(epoch: 3))
        XCTAssertTrue(receiving.central.isArmed, "focus changes never stop receiving")
    }

    func testCoordinatorForwardsEventsAndStatus() async throws {
        let r = rig()
        r.focus.onChange?(Self.editable(epoch: 3))

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
        let id = try r.deliver(.pointerOpen(grant: grant, wifi: nil))
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
        let id = try r.deliver(.pointerOpen(grant: (r.pointer?.grant ?? 0) &+ 1, wifi: nil))
        try r.pump()
        XCTAssertEqual(r.acks, [Ack(eventId: id, result: .notAuthorized)])
        XCTAssertEqual(r.pointer?.isOpen, false)
    }

    func testPointerOpenWithoutAPointerReceiverIsRefused() throws {
        let r = rig()
        r.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(r)
        let id = try r.deliver(.pointerOpen(grant: 5, wifi: nil))
        try r.pump()
        XCTAssertEqual(r.acks, [Ack(eventId: id, result: .notAuthorized)])
    }

    func testALostLinkClosesThePointerChannel() throws {
        let r = pointerRig()
        r.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(r)
        _ = try r.deliver(.pointerOpen(grant: try XCTUnwrap(r.pointer?.grant), wifi: nil))
        XCTAssertEqual(r.pointer?.isOpen, true)
        r.central.handleLink(.disconnected(r.peripheral))
        XCTAssertEqual(r.pointer?.isOpen, false)
        XCTAssertNil(r.pointer?.grant)
    }

    // MARK: Wi-Fi assist wiring (spec W1, W8, W9, W10)

    private func openPointer(_ r: Rig, wifi: WifiOffer?) throws -> UUID {
        let id = try r.deliver(.pointerOpen(grant: try XCTUnwrap(r.pointer?.grant), wifi: wifi))
        try r.pump()
        return id
    }

    private func wifiRigWithChannelOpen(_ offer: WifiOffer = WifiTestData.offer) throws -> Rig {
        let r = wifiRig()
        r.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(r)
        _ = try openPointer(r, wifi: offer)
        XCTAssertEqual(r.wifi?.isProbing, true, "set up: probing")
        return r
    }

    /// A signed-off stop: nothing more goes out, the transport is closed and the log says why.
    private func assertProbingStopped(_ r: Rig, why: String, file: StaticString = #filePath, line: UInt = #line) {
        let sent = r.wifiTransport.sent.count
        XCTAssertEqual(r.wifi?.isProbing, false, file: file, line: line)
        XCTAssertGreaterThanOrEqual(r.wifiTransport.closes, 1, file: file, line: line)
        XCTAssertTrue(r.wifiTimers.active.isEmpty, file: file, line: line)
        r.wifiTimers.tick()
        XCTAssertEqual(r.wifiTransport.sent.count, sent, "no probe after the stop", file: file, line: line)
        XCTAssertTrue(r.wifiLog.lines.contains("wifi_probe_stop why=\(why)"), r.wifiLog.lines.joined(separator: ", "), file: file, line: line)
    }

    func testAGrantedOpenWithWifiProbesEveryTargetAtOnceAndThenEvery250Ms() throws {
        let r = wifiRig()
        r.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(r)
        let id = try openPointer(r, wifi: WifiTestData.offer)
        XCTAssertEqual(r.acks, [Ack(eventId: id, result: .posted)])
        XCTAssertEqual(r.wifiTransport.opened, [[WifiTestData.target, WifiTestData.second]])
        XCTAssertEqual(r.wifiTransport.sent.count, 1)
        XCTAssertEqual(r.wifiLog.lines, ["wifi_probe_start targets=2"])
        XCTAssertEqual(r.wifiTimers.active.map(\.interval), [0.25])
        r.wifiTimers.tick()
        XCTAssertEqual(r.wifiTransport.sent.count, 2)

        let opener = try r.phoneChannels().opener(.wifiProbe)
        for packet in r.wifiTransport.sent {
            XCTAssertEqual(try? opener.open(packet).get(), Data(count: 16), "the phone opens each probe with this connection's probe key")
        }
        XCTAssertEqual(opener.lastOpenedCounter, 2)
    }

    func testNoProbeWithoutAWifiOfferOrWhenTheOpenIsRefused() throws {
        let plain = wifiRig()
        plain.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(plain)
        _ = try openPointer(plain, wifi: nil)
        XCTAssertEqual(plain.pointer?.isOpen, true)
        XCTAssertTrue(plain.wifiTransport.opened.isEmpty)
        XCTAssertTrue(plain.wifiTransport.sent.isEmpty)
        XCTAssertTrue(plain.wifiTimers.entries.isEmpty)

        let refused = wifiRig()
        refused.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(refused)
        let id = try refused.deliver(.pointerOpen(grant: (refused.pointer?.grant ?? 0) &+ 1, wifi: WifiTestData.offer))
        try refused.pump()
        XCTAssertEqual(refused.acks, [Ack(eventId: id, result: .notAuthorized)])
        XCTAssertTrue(refused.wifiTransport.opened.isEmpty)
        XCTAssertTrue(refused.wifiTransport.sent.isEmpty)

        let off = wifiRig()
        off.focus.onChange?(Self.editable(epoch: 3))
        try bringLinkUp(off)
        let grant = try XCTUnwrap(off.pointer?.grant)
        off.pointer?.setEnabled(false)
        _ = try off.deliver(.pointerOpen(grant: grant, wifi: WifiTestData.offer))
        XCTAssertTrue(off.wifiTransport.sent.isEmpty, "the switch is off: nothing is probed")
    }

    func testClosingTheChannelStopsTheProbes() throws {
        let r = try wifiRigWithChannelOpen()
        _ = try r.deliver(.pointerClose)
        assertProbingStopped(r, why: "close")
    }

    func testALostLinkStopsTheProbes() throws {
        let r = try wifiRigWithChannelOpen()
        r.central.handleLink(.disconnected(r.peripheral))
        assertProbingStopped(r, why: "disconnect")
    }

    func testAFailedHandshakeStopsTheProbes() throws {
        let r = try wifiRigWithChannelOpen()
        // An event of another session on an authenticated link fails authentication.
        let message = try r.phone.sealed(.ping(shownAtMs: 1, connectedAtMs: 2), session: UUID(), seq: 99, epoch: 3)
        for frame in try r.phone.frames(message) { r.central.receive(eventData: frame) }
        assertProbingStopped(r, why: "disconnect")
    }

    func testTurningTheTouchpadSwitchOffStopsTheProbes() throws {
        let r = try wifiRigWithChannelOpen()
        r.pointer?.setEnabled(false)
        assertProbingStopped(r, why: "grant_changed")
    }

    func testARenewedGrantStopsTheProbes() throws {
        let r = try wifiRigWithChannelOpen()
        let channels = try r.phoneChannels()
        for _ in 0..<PointerReceiver.maxConsecutiveFailures {
            var forged = try channels.sealer(.pointer).seal(Data(count: 16))
            forged[forged.count - 1] ^= 0x01
            r.central.receive(eventData: forged)
        }
        XCTAssertEqual(r.pointer?.isOpen, false)
        assertProbingStopped(r, why: "grant_changed")
    }

    func testARefusedOpenWhileProbingStopsTheProbes() throws {
        let r = try wifiRigWithChannelOpen()
        _ = try r.deliver(.pointerOpen(grant: (r.pointer?.grant ?? 0) &+ 1, wifi: WifiTestData.offer))
        assertProbingStopped(r, why: "refused")
    }

    func testAnOpenWithoutWifiWhileProbingStopsTheProbes() throws {
        let r = try wifiRigWithChannelOpen()
        _ = try openPointer(r, wifi: nil)
        assertProbingStopped(r, why: "no_wifi")
    }

    func testANewOpenWithWifiReplacesTheTargets() throws {
        let r = try wifiRigWithChannelOpen()
        _ = try openPointer(r, wifi: WifiTestData.otherOffer)
        XCTAssertEqual(r.wifiTransport.opened.last, [WifiTarget(address: "172.16.0.9", port: 4_000)])
        XCTAssertEqual(r.wifiTimers.active.count, 1)
        XCTAssertEqual(r.wifi?.isProbing, true)
        // The old target is no longer a source to listen to.
        let channels = try r.phoneChannels()
        let click = try channels.sealer(.pointer).seal(
            PointerPayload(opcode: .click, buttons: 0, dx: 0, dy: 0, dt: 0, arg: PointerPayload.clickArg(button: 0, count: 1), buttonSeq: 0).encode())
        r.wifiTransport.deliver(from: WifiTestData.target, click)
        XCTAssertTrue(r.pointerOutput.actions.isEmpty)
    }

    // MARK: Datagrams from the phone

    private func click(_ r: Rig) throws -> Data {
        try r.phoneChannels().sealer(.pointer).seal(
            PointerPayload(opcode: .click, buttons: 0, dx: 0, dy: 0, dt: 0, arg: PointerPayload.clickArg(button: 0, count: 1), buttonSeq: 0).encode())
    }

    private func clickCount(_ r: Rig) -> Int {
        r.pointerOutput.actions.filter { if case .click = $0 { true } else { false } }.count
    }

    func testADatagramFromTheProbedPhoneActsLikeTheSamePacketOverBluetooth() throws {
        let r = try wifiRigWithChannelOpen()
        r.wifiTransport.deliver(from: WifiTestData.target, try click(r))
        XCTAssertEqual(clickCount(r), 1)
        r.central.receive(eventData: try click(r))
        XCTAssertEqual(clickCount(r), 2, "both routes reach the same touchpad")
    }

    func testADatagramFromAnythingElseIsIgnored() throws {
        let r = try wifiRigWithChannelOpen()
        r.wifiTransport.deliver(from: WifiTarget(address: "192.168.1.23", port: 50_124), try click(r))
        r.wifiTransport.deliver(from: WifiTarget(address: "203.0.113.7", port: 50_123), try click(r))
        r.wifiTransport.deliver(from: WifiTestData.target, try click(r).dropLast())
        XCTAssertEqual(clickCount(r), 0)
    }

    func testTwentyBadDatagramsDoNotRenewTheGrantButEightBadBluetoothPacketsDo() throws {
        let r = try wifiRigWithChannelOpen()
        let grant = r.pointer?.grant
        let statuses = r.statuses.count
        let channels = try r.phoneChannels()
        func forged() throws -> Data {
            var packet = try channels.sealer(.pointer).seal(Data(count: 16))
            packet[packet.count - 1] ^= 0x01
            return packet
        }
        for _ in 0..<20 { r.wifiTransport.deliver(from: WifiTestData.target, try forged()) }
        try r.pump()
        XCTAssertEqual(r.pointer?.grant, grant)
        XCTAssertEqual(r.pointer?.isOpen, true)
        XCTAssertEqual(r.statuses.count, statuses, "no new status: the phone is not told to open again")
        XCTAssertEqual(r.wifi?.isProbing, true)

        for _ in 0..<PointerReceiver.maxConsecutiveFailures { r.central.receive(eventData: try forged()) }
        try r.pump()
        XCTAssertNotEqual(r.pointer?.grant, grant)
        XCTAssertEqual(r.statuses.count, statuses + 1)
    }

    func testAPacketThatArrivedOverBluetoothIsAReplayOverUDPAndTheOtherWayRound() throws {
        let r = try wifiRigWithChannelOpen()
        let first = try click(r)
        r.central.receive(eventData: first)
        r.wifiTransport.deliver(from: WifiTestData.target, first)
        XCTAssertEqual(clickCount(r), 1)
        let second = try click(r)
        r.wifiTransport.deliver(from: WifiTestData.target, second)
        r.central.receive(eventData: second)
        XCTAssertEqual(clickCount(r), 2)
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
