import CoreGraphics
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

/// The coordinator against a real `ReceiverBLECentral` with a fake radio and a real `EventPipeline` with fake input.
/// Nothing here touches Bluetooth, Accessibility or the real input stream.
@MainActor
final class ReceiverCoordinatorWiringTests: XCTestCase {
    @MainActor private final class FakeDriver: CentralDriving {
        var controlWrites: [Data] = []
        func startScan() {}
        func stopScan() {}
        func connect(_ id: UUID) {}
        func discover(_ id: UUID) {}
        func cancel(_ id: UUID) {}
        func forget(_ id: UUID) {}
        func writeControl(_ data: Data) { controlWrites.append(data) }
        var messages: [ControlMessage] { controlWrites.compactMap { try? ControlCodec.decode($0) } }
        var acks: [Ack] { messages.compactMap { if case .ack(let ack) = $0 { ack } else { nil } } }
    }

    @MainActor private final class CountingPoster: EventPosting {
        var batches = 0
        func post(_ events: [CGEvent]) { batches += 1 }
    }

    @MainActor private final class AsciiController: InputSourceControlling {
        func currentID() -> String { InputSourceSwitcher.asciiID }
        func select(_ id: String) -> Bool { true }
    }

    private struct Rig {
        let coordinator: ReceiverCoordinator
        let central: ReceiverBLECentral
        let focus: FocusMonitor
        let driver: FakeDriver
        let poster: CountingPoster
        let peripheral = UUID()
    }

    private func rig() -> Rig {
        let name = "rk.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let driver = FakeDriver()
        let central = ReceiverBLECentral(defaults: defaults, makeDriver: { _ in driver })
        let focus = FocusMonitor()
        let poster = CountingPoster()
        let current = Self.editable(epoch: 3)
        let pipeline = EventPipeline(
            snapshot: { current },
            switcher: InputSourceSwitcher(controller: AsciiController(), composition: nil, settle: { _ in }),
            injector: TextInjector(poster: poster),
            sendAck: { [weak central] ack in central?.send(.ack(ack)) },
            noteValidEvent: { [weak central] in central?.noteEvent() }
        )
        let coordinator = ReceiverCoordinator(focus: focus, central: central, pipeline: pipeline)
        coordinator.start()
        return Rig(coordinator: coordinator, central: central, focus: focus, driver: driver, poster: poster)
    }

    private static func editable(epoch: UInt64) -> FocusSnapshot {
        FocusSnapshot(axTrusted: true, frontmostPID: 42, appName: "TextEdit", editable: true, epoch: epoch)
    }

    private func bringLinkUp(_ r: Rig) {
        r.central.handleLink(.power(.poweredOn))
        r.central.handleLink(.discovered(r.peripheral))
        r.central.handleLink(.connected(r.peripheral))
        r.central.handleLink(.linkReady(r.peripheral))
    }

    private func deliver(_ kind: EventKind, id: UUID = UUID(), to central: ReceiverBLECentral) throws -> UUID {
        let event = KeyboardEvent(
            protocolVersion: KeyboardEvent.currentVersion, eventId: id, sessionId: UUID(), seq: 1, focusEpoch: 3, kind: kind)
        let message = try PeripheralCodec.encode(.event(event))
        for frame in try FrameCodec.split(message, messageId: 0, maxFrameBytes: 182) { central.receive(eventData: frame) }
        return id
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

        bringLinkUp(r)
        XCTAssertEqual(r.driver.messages, [.status(ReceiverStatus(ready: true, appName: "TextEdit", focusEpoch: 3))],
                       "the first status is written when the link becomes ready")

        let id = try deliver(.text("A"), to: r.central)
        await waitUntil { !r.driver.acks.isEmpty }
        XCTAssertEqual(r.driver.acks, [Ack(eventId: id, result: .posted)])
        XCTAssertEqual(r.poster.batches, 1)
    }

    func testPingReachesThePipelineAndIsAckedPong() async throws {
        let r = rig()
        r.focus.onChange?(Self.editable(epoch: 3))
        bringLinkUp(r)
        let id = try deliver(.ping(shownAtMs: 1, connectedAtMs: 2), to: r.central)
        await waitUntil { !r.driver.acks.isEmpty }
        XCTAssertEqual(r.driver.acks, [Ack(eventId: id, result: .pong)])
        XCTAssertEqual(r.poster.batches, 0)
    }

    func testLinkLossDropsQueuedEventsButKeepsTheDeduplicator() async throws {
        let r = rig()
        r.focus.onChange?(Self.editable(epoch: 3))
        bringLinkUp(r)

        let id = try deliver(.text("A"), to: r.central)
        await waitUntil { r.driver.acks.count == 1 }
        XCTAssertEqual(r.poster.batches, 1)

        // Queued behind nothing yet read: the link drops before the consumer runs, so they are never typed.
        _ = try deliver(.text("B"), to: r.central)
        r.central.handleLink(.disconnected(r.peripheral))
        bringLinkUp(r)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(r.driver.acks.count, 1, "the event queued before the link loss is dropped, not typed later")
        XCTAssertEqual(r.poster.batches, 1)

        // The same event again after the reconnect is recognised: acked with the original code, not typed twice.
        _ = try deliver(.text("A"), id: id, to: r.central)
        await waitUntil { r.driver.acks.count == 2 }
        XCTAssertEqual(r.driver.acks.last, Ack(eventId: id, result: .posted))
        XCTAssertEqual(r.poster.batches, 1)
    }
}
