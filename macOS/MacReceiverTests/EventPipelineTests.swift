import CoreGraphics
import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

/// The pipeline runs against fakes: events go to a recording poster, never to the real input stream, and nothing here
/// needs Accessibility trust, the real input source or Bluetooth.
@MainActor
final class EventPipelineTests: XCTestCase {
    private let zhuyin = "com.apple.inputmethod.TCIM.Zhuyin"

    @MainActor private final class RecordingPoster: EventPosting {
        var batches: [[CGEvent]] = []
        func post(_ events: [CGEvent]) { batches.append(events) }
        var keycodes: [Int64] { batches.map { $0[0].getIntegerValueField(.keyboardEventKeycode) } }
    }

    @MainActor private final class FakeController: InputSourceControlling {
        var current: String
        var selected: [String] = []
        init(current: String) { self.current = current }
        func currentID() -> String { current }
        func select(_ id: String) -> Bool { selected.append(id); current = id; return true }
    }

    @MainActor private final class FakeComposition: CompositionControlling {
        var value: CompositionState
        var cancels = 0
        init(_ value: CompositionState) { self.value = value }
        func state() -> CompositionState { value }
        func cancel() { cancels += 1 }
    }

    private struct Harness {
        let pipeline: EventPipeline
        let poster: RecordingPoster
        let controller: FakeController
        let state: State
    }

    private final class State {
        var snapshots: [FocusSnapshot?]
        var reads = 0
        var acks: [Ack] = []
        var noted = 0
        var pings: [[Int64]] = []
        init(_ snapshots: [FocusSnapshot?]) { self.snapshots = snapshots }
        func next() -> FocusSnapshot? {
            reads += 1
            return snapshots.count > 1 ? snapshots.removeFirst() : snapshots.first ?? nil
        }
    }

    private func snapshot(epoch: UInt64 = 5, editable: Bool = true, trusted: Bool = true) -> FocusSnapshot {
        FocusSnapshot(axTrusted: trusted, frontmostPID: 42, appName: "TextEdit", editable: editable, epoch: epoch)
    }

    private func harness(
        snapshots: [FocusSnapshot?], current: String = InputSourceSwitcher.asciiID,
        composition: CompositionControlling? = nil, settle: @escaping (Double) async -> Void = { _ in }
    ) -> Harness {
        let poster = RecordingPoster()
        let controller = FakeController(current: current)
        let state = State(snapshots)
        let pipeline = EventPipeline(
            snapshot: { state.next() },
            switcher: InputSourceSwitcher(controller: controller, composition: composition, settle: settle),
            injector: TextInjector(poster: poster),
            sendAck: { state.acks.append($0) },
            noteValidEvent: { state.noted += 1 },
            onPing: { state.pings.append([$0, $1]) }
        )
        return Harness(pipeline: pipeline, poster: poster, controller: controller, state: state)
    }

    private func frame(_ kind: EventKind, epoch: UInt64? = 5, id: UUID = UUID(), version: Int = 1) throws -> (Data, UUID) {
        let event = KeyboardEvent(protocolVersion: version, eventId: id, sessionId: UUID(), seq: 1, focusEpoch: epoch, kind: kind)
        return (try EventCodec.encode(event, maxBytes: 400), id)
    }

    // MARK: Decision to ack mapping

    func testGuardDecisionsMapToTheirAckCodes() {
        XCTAssertNil(EventPipeline.ackCode(for: .allow))
        XCTAssertEqual(EventPipeline.ackCode(for: .notAuthorized), .notAuthorized)
        XCTAssertEqual(EventPipeline.ackCode(for: .noFocus), .noFocus)
        XCTAssertEqual(EventPipeline.ackCode(for: .staleFocus), .staleFocus)
    }

    func testSwitchResultMapsToAckCode() {
        func code(_ r: SwitchResult, late: InjectionDecision = .allow, injected: Bool = true) -> AckCode {
            EventPipeline.ackCode(result: r, lateDecision: late, injected: injected)
        }
        XCTAssertEqual(code(.injected), .posted)
        XCTAssertEqual(code(.switchFailed), .switchFailed)
        XCTAssertEqual(code(.compositionActive), .compositionActive)
        XCTAssertEqual(code(.injected, late: .staleFocus, injected: false), .staleFocus)
        XCTAssertEqual(code(.injected, late: .noFocus, injected: false), .noFocus)
        XCTAssertEqual(code(.injected, injected: false), .malformed)
        XCTAssertEqual(code(.refused, late: .staleFocus, injected: false), .staleFocus)
        XCTAssertEqual(code(.refused, late: .noFocus, injected: false), .noFocus)
        XCTAssertEqual(code(.refused, injected: false), .staleFocus)
    }

    // MARK: Per-event behaviour

    func testAllowedTextPostsOnceAndAcksPosted() async throws {
        let h = harness(snapshots: [snapshot()])
        let (data, id) = try frame(.text("A"))
        await h.pipeline.process(data)
        XCTAssertEqual(h.poster.batches.count, 1)
        XCTAssertEqual(h.state.acks, [Ack(eventId: id, result: .posted)])
        XCTAssertEqual(h.state.noted, 1)
    }

    func testBackspaceAndReturnPostTheirKeys() async throws {
        let h = harness(snapshots: [snapshot()])
        await h.pipeline.process(try frame(.backspace).0)
        await h.pipeline.process(try frame(.returnKey).0)
        XCTAssertEqual(h.poster.keycodes, [51, 36])
        XCTAssertEqual(h.state.acks.map(\.result), [.posted, .posted])
    }

    func testStaleEpochRefusesWithoutPosting() async throws {
        let h = harness(snapshots: [snapshot(epoch: 6)])
        let (data, id) = try frame(.text("A"), epoch: 5)
        await h.pipeline.process(data)
        XCTAssertEqual(h.poster.batches.count, 0)
        XCTAssertEqual(h.state.acks, [Ack(eventId: id, result: .staleFocus)])
        XCTAssertEqual(h.state.noted, 1, "a decoded event still counts as receive activity")
    }

    func testNonEditableFocusAcksNoFocus() async throws {
        let h = harness(snapshots: [snapshot(editable: false)])
        await h.pipeline.process(try frame(.text("A")).0)
        XCTAssertEqual(h.state.acks.map(\.result), [.noFocus])
        XCTAssertEqual(h.poster.batches.count, 0)
    }

    func testMissingOrUntrustedSnapshotAcksNotAuthorized() async throws {
        for snap in [nil, snapshot(trusted: false)] {
            let h = harness(snapshots: [snap])
            await h.pipeline.process(try frame(.text("A")).0)
            XCTAssertEqual(h.state.acks.map(\.result), [.notAuthorized])
            XCTAssertEqual(h.poster.batches.count, 0)
        }
    }

    func testFocusIsReadFreshForEveryEvent() async throws {
        let h = harness(snapshots: [snapshot()])
        await h.pipeline.process(try frame(.text("A")).0)
        await h.pipeline.process(try frame(.text("B")).0)
        // One read before the guard and one right before posting, for each event.
        XCTAssertEqual(h.state.reads, 4)
    }

    func testFocusChangingDuringTheSwitchRefusesAtThePostingStep() async throws {
        // First read allows; the re-check inside the switch window sees a new epoch.
        let h = harness(snapshots: [snapshot(epoch: 5), snapshot(epoch: 6)], current: zhuyin)
        await h.pipeline.process(try frame(.text("A"), epoch: 5).0)
        XCTAssertEqual(h.poster.batches.count, 0)
        XCTAssertEqual(h.state.acks.map(\.result), [.staleFocus])
        XCTAssertEqual(h.controller.current, zhuyin, "the original input source is restored")
    }

    func testOpenCompositionAcksCompositionActive() async throws {
        let composition = FakeComposition(.composing)
        let h = harness(snapshots: [snapshot()], current: zhuyin, composition: composition)
        await h.pipeline.process(try frame(.text("A")).0)
        XCTAssertEqual(h.state.acks.map(\.result), [.compositionActive])
        XCTAssertEqual(h.poster.batches.count, 0)
        XCTAssertEqual(composition.cancels, 1)
        XCTAssertEqual(h.controller.selected, [])
    }

    func testEventWithoutEpochIsRefusedAsStaleWithoutAFocusRead() async throws {
        let h = harness(snapshots: [snapshot()])
        let (data, id) = try frame(.text("A"), epoch: nil)
        await h.pipeline.process(data)
        XCTAssertEqual(h.state.acks, [Ack(eventId: id, result: .staleFocus)])
        XCTAssertEqual(h.poster.batches.count, 0)
        XCTAssertEqual(h.state.reads, 0)
        XCTAssertEqual(h.state.noted, 1)
    }

    func testFocusMovingWhileQueuedBehindTheGateNeverPostsEscape() async throws {
        // First read allows; the re-check made after the gate and before Escape sees a new epoch.
        let composition = FakeComposition(.composing)
        let h = harness(snapshots: [snapshot(epoch: 5), snapshot(epoch: 6)], current: zhuyin, composition: composition)
        let (data, id) = try frame(.text("A"), epoch: 5)
        await h.pipeline.process(data)
        XCTAssertEqual(composition.cancels, 0, "Escape must not reach a field that was never authorized")
        XCTAssertEqual(h.controller.selected, [])
        XCTAssertEqual(h.poster.batches.count, 0)
        XCTAssertEqual(h.state.acks, [Ack(eventId: id, result: .staleFocus)])
    }

    func testPingIsAcknowledgedWithoutAFocusReadOrPosting() async throws {
        let h = harness(snapshots: [snapshot()])
        let (data, id) = try frame(.ping(shownAtMs: 1, connectedAtMs: 2))
        await h.pipeline.process(data)
        XCTAssertEqual(h.state.acks, [Ack(eventId: id, result: .posted)])
        XCTAssertEqual(h.state.reads, 0)
        XCTAssertEqual(h.poster.batches.count, 0)
    }

    func testEmptyTextIsMalformed() async throws {
        let h = harness(snapshots: [snapshot()])
        await h.pipeline.process(try frame(.text("")).0)
        XCTAssertEqual(h.state.acks.map(\.result), [.malformed])
        XCTAssertEqual(h.poster.batches.count, 0)
    }

    func testUndecodableBytesAckMalformedWithoutCountingAsActivity() async throws {
        let h = harness(snapshots: [snapshot()])
        await h.pipeline.process(Data("{".utf8))
        await h.pipeline.process(try frame(.text("A"), version: 2).0)
        XCTAssertEqual(h.state.acks, [Ack(eventId: Ack.unknownEventId, result: .malformed),
                                      Ack(eventId: Ack.unknownEventId, result: .malformed)])
        XCTAssertEqual(h.state.noted, 0)
        XCTAssertEqual(h.poster.batches.count, 0)
    }

    func testLongTextIsChunkedAndAcksPostedOnce() async throws {
        let h = harness(snapshots: [snapshot()])
        await h.pipeline.process(try frame(.text(String(repeating: "a", count: 45))).0)
        XCTAssertEqual(h.poster.batches.count, 3)
        XCTAssertEqual(h.state.acks.map(\.result), [.posted])
    }

    // MARK: Order

    func testSubmittedEventsAreProcessedStrictlyInArrivalOrder() async throws {
        // Each switch settles with real suspension, so a non-serial pipeline would interleave these.
        let h = harness(snapshots: [snapshot()], current: zhuyin, settle: { _ in
            for _ in 0..<5 { await Task.yield() }
        })
        let ids = (0..<4).map { _ in UUID() }
        for id in ids { h.pipeline.submit(try frame(.text("x"), id: id).0) }
        let deadline = Date().addingTimeInterval(3)
        while h.state.acks.count < ids.count, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(h.state.acks.map(\.eventId), ids)
        XCTAssertEqual(h.poster.batches.count, 4)
        XCTAssertEqual(h.controller.selected, [InputSourceSwitcher.asciiID, zhuyin,
                                               InputSourceSwitcher.asciiID, zhuyin,
                                               InputSourceSwitcher.asciiID, zhuyin,
                                               InputSourceSwitcher.asciiID, zhuyin])
    }

    // MARK: T06 ping and link loss

    func testPingWithoutAFocusEpochIsAckedAndRecordedNotRefused() async throws {
        let h = harness(snapshots: [snapshot()])
        let (data, id) = try frame(.ping(shownAtMs: 1_000, connectedAtMs: 1_480), epoch: nil)
        await h.pipeline.process(data)
        XCTAssertEqual(h.state.acks, [Ack(eventId: id, result: .posted)])
        XCTAssertEqual(h.state.pings, [[1_000, 1_480]])
        XCTAssertEqual(h.state.reads, 0, "no focus read for a probe")
        XCTAssertEqual(h.poster.batches.count, 0)
        XCTAssertTrue(h.controller.selected.isEmpty, "no input source switch for a probe")
    }

    func testTypedEventsNeverReachThePingHook() async throws {
        let h = harness(snapshots: [snapshot()])
        await h.pipeline.process(try frame(.text("A")).0)
        XCTAssertEqual(h.state.pings, [])
    }

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testDiscardQueuedDropsEventsThatHaveNotStartedAndLaterOnesStillRun() async throws {
        let h = harness(snapshots: [snapshot()])
        // The consumer cannot run before this test yields, so all three are still queued.
        for _ in 0..<3 { h.pipeline.submit(try frame(.text("A")).0) }
        h.pipeline.discardQueued()
        h.pipeline.submit(try frame(.text("B")).0)
        await waitUntil { h.state.acks.count >= 1 }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(h.state.acks.count, 1, "only the event submitted after the link loss is processed")
        XCTAssertEqual(h.poster.batches.count, 1)
    }

    func testPipelineIsReleasedEvenThoughItsConsumerIsWaiting() async throws {
        weak var weakPipeline: EventPipeline?
        do {
            let h = harness(snapshots: [snapshot()])
            h.pipeline.submit(try frame(.backspace).0)
            await waitUntil { h.state.acks.count == 1 }
            weakPipeline = h.pipeline
        }
        await waitUntil { weakPipeline == nil }
        XCTAssertNil(weakPipeline)
    }
}
