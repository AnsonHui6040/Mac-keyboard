import ApplicationServices
import CoreGraphics
import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

/// A password field is an AXTextField with subrole AXSecureTextField; none of its states may ever count as editable.
final class SecureFieldClassificationTests: XCTestCase {
    func testSecureSubroleWithTextRoleIsNotEditable() {
        XCTAssertFalse(FocusMonitor.isEditable(role: "AXTextField", subrole: "AXSecureTextField", valueSettable: false))
    }

    func testSecureSubroleWithSettableValueIsNotEditable() {
        XCTAssertFalse(FocusMonitor.isEditable(role: "AXTextField", subrole: "AXSecureTextField", valueSettable: true))
        XCTAssertFalse(FocusMonitor.isEditable(role: "AXGroup", subrole: "AXSecureTextField", valueSettable: true))
        XCTAssertFalse(FocusMonitor.isEditable(role: nil, subrole: "AXSecureTextField", valueSettable: true))
    }

    func testNormalTextFieldStaysEditable() {
        XCTAssertTrue(FocusMonitor.isEditable(role: "AXTextField", subrole: nil, valueSettable: false))
        XCTAssertTrue(FocusMonitor.isEditable(role: "AXTextField", subrole: "AXSearchField", valueSettable: false))
        XCTAssertTrue(FocusMonitor.isEditable(role: "AXTextArea", subrole: "AXStandardWindow", valueSettable: false))
    }

    func testMissingSubroleAttributeIsNotSecure() {
        for error in [AXError.noValue, .attributeUnsupported] {
            let read = FocusMonitor.subroleRead(error: error, value: nil)
            XCTAssertEqual(read, .value(nil), "\(error)")
            XCTAssertTrue(FocusMonitor.isEditable(role: "AXTextField", subroleRead: read, valueSettable: false), "\(error)")
        }
    }

    func testSuccessfulSubroleReadCarriesTheValue() {
        XCTAssertEqual(FocusMonitor.subroleRead(error: .success, value: "AXSecureTextField"), .value("AXSecureTextField"))
        XCTAssertEqual(FocusMonitor.subroleRead(error: .success, value: nil), .value(nil))
        let secure = FocusMonitor.subroleRead(error: .success, value: "AXSecureTextField")
        XCTAssertFalse(FocusMonitor.isEditable(role: "AXTextField", subroleRead: secure, valueSettable: true))
    }

    func testFailingSubroleReadIsNotEditable() {
        for error in [AXError.cannotComplete, .apiDisabled, .invalidUIElement, .illegalArgument, .failure, .notImplemented] {
            let read = FocusMonitor.subroleRead(error: error, value: nil)
            XCTAssertEqual(read, .unreadable, "\(error)")
            XCTAssertFalse(FocusMonitor.isEditable(role: "AXTextField", subroleRead: read, valueSettable: true), "\(error)")
        }
    }

    func testOnlyAReadSecureSubroleReportsAPassword() {
        XCTAssertTrue(FocusMonitor.isSecure(subroleRead: .value("AXSecureTextField")))
        XCTAssertFalse(FocusMonitor.isSecure(subroleRead: .value("AXSearchField")))
        XCTAssertFalse(FocusMonitor.isSecure(subroleRead: .value(nil)))
        // Unreadable: not editable (above), but also not called a password, because the status would be a guess.
        XCTAssertFalse(FocusMonitor.isSecure(subroleRead: .unreadable))
    }

    func testScreenLockedReadsTheSessionDictionary() {
        XCTAssertTrue(FocusEnvironment.screenLocked(session: ["CGSSessionScreenIsLocked": true]))
        XCTAssertFalse(FocusEnvironment.screenLocked(session: ["CGSSessionScreenIsLocked": false]))
        XCTAssertFalse(FocusEnvironment.screenLocked(session: [:]))
        XCTAssertFalse(FocusEnvironment.screenLocked(session: nil))
    }
}

@MainActor
final class InputBlockedFocusTests: XCTestCase {
    private final class Switch { var blocked = false }

    private func monitor(_ gate: Switch, reader: ScriptedFocusReader) -> FocusMonitor {
        let environment = FocusEnvironment(
            trusted: { true }, frontmost: { (42, "TextEdit") }, ownPID: 1, inputBlocked: { gate.blocked })
        return FocusMonitor(reader: reader, environment: environment)
    }

    func testBlockedEnvironmentGivesNonReadySnapshotAndUnblockedReturnsToReady() async {
        let gate = Switch()
        let m = monitor(gate, reader: ScriptedFocusReader([FocusFixtures.elementA]))
        let open = await m.refreshNow()
        XCTAssertTrue(open.editable)
        XCTAssertTrue(FocusTransition.status(for: open).ready)

        gate.blocked = true
        let blocked = await m.refreshNow()
        XCTAssertFalse(blocked.editable)
        XCTAssertTrue(blocked.axTrusted)
        XCTAssertEqual(blocked.epoch, open.epoch, "blocking does not move the epoch")
        XCTAssertFalse(FocusTransition.status(for: blocked).ready)

        gate.blocked = false
        let back = await m.refreshNow()
        XCTAssertTrue(back.editable)
        XCTAssertEqual(back.epoch, open.epoch)
        XCTAssertTrue(FocusTransition.status(for: back).ready)
    }

    func testSnapshotSaysInputBlockedWhenTheEnvironmentIsBlocked() async {
        let gate = Switch()
        let m = monitor(gate, reader: ScriptedFocusReader([FocusFixtures.elementA]))
        let open = await m.refreshNow()
        XCTAssertFalse(open.inputBlocked)
        gate.blocked = true
        let blocked = await m.refreshNow()
        XCTAssertTrue(blocked.inputBlocked)
        XCTAssertFalse(blocked.editable)
        let status = FocusTransition.status(for: blocked)
        XCTAssertTrue(status.inputBlocked); XCTAssertFalse(status.ready)
        gate.blocked = false
        let back = await m.refreshNow()
        XCTAssertFalse(back.inputBlocked)
        XCTAssertFalse(FocusTransition.status(for: back).inputBlocked)
    }

    func testSecureFieldSubroleGivesABlockedNotEditableSnapshotWithoutMovingTheEpochRule() async {
        let gate = Switch()
        let secureA = FocusReadResult(element: FocusFixtures.elementA.element, editable: false, secure: true)
        let m = monitor(gate, reader: ScriptedFocusReader([FocusFixtures.elementA, secureA]))
        let open = await m.refreshNow()
        XCTAssertFalse(open.inputBlocked)
        let secure = await m.refreshNow()
        XCTAssertTrue(secure.inputBlocked)
        XCTAssertFalse(secure.editable)
        XCTAssertEqual(secure.epoch, open.epoch, "same element, so the epoch rule is untouched")
    }

    func testAnUnreadableSubroleIsNotReportedAsAPassword() async {
        let gate = Switch()
        let unreadable = FocusReadResult(element: FocusFixtures.elementA.element, editable: false, secure: false)
        let m = monitor(gate, reader: ScriptedFocusReader([unreadable]))
        let snapshot = await m.refreshNow()
        XCTAssertFalse(snapshot.editable)
        XCTAssertFalse(snapshot.inputBlocked)
    }

    func testSecureInputTurningOnWithNoFocusChangeIsPublished() async {
        let gate = Switch()
        let m = monitor(gate, reader: ScriptedFocusReader([FocusFixtures.elementA]))
        var published: [FocusSnapshot] = []
        m.onChange = { published.append($0) }
        _ = await m.refreshNow()
        _ = await m.refreshNow()
        XCTAssertEqual(published.count, 1, "an unchanged poll publishes nothing")
        gate.blocked = true
        _ = await m.refreshNow()
        XCTAssertEqual(published.count, 2)
        XCTAssertEqual(published.last?.inputBlocked, true)
        XCTAssertEqual(published.last?.epoch, published.first?.epoch)
        gate.blocked = false
        _ = await m.refreshNow()
        XCTAssertEqual(published.count, 3)
        XCTAssertEqual(published.last?.inputBlocked, false)
        XCTAssertTrue(FocusTransition.statusChanged(previous: published[1], next: published[2]))
    }

    func testFocusGuardAnswersNoFocusWhileBlocked() async {
        let gate = Switch()
        gate.blocked = true
        let m = monitor(gate, reader: ScriptedFocusReader([FocusFixtures.elementA]))
        let snapshot = await m.refreshNow()
        XCTAssertEqual(FocusGuard.authorize(eventEpoch: snapshot.epoch, current: snapshot), .noFocus)
    }
}

final class InputBlockedStatusTests: XCTestCase {
    private func snap(editable: Bool = false, blocked: Bool, epoch: UInt64 = 3) -> FocusSnapshot {
        FocusSnapshot(
            axTrusted: true, frontmostPID: 1, appName: "Safari", editable: editable, epoch: epoch, inputBlocked: blocked)
    }

    func testStatusPassesInputBlockedThrough() {
        XCTAssertTrue(FocusTransition.status(for: snap(blocked: true)).inputBlocked)
        XCTAssertFalse(FocusTransition.status(for: snap(blocked: false)).inputBlocked)
    }

    func testStatusIsNeverReadyWhileBlockedEvenIfEditableWereSet() {
        XCTAssertFalse(FocusTransition.status(for: snap(editable: true, blocked: true)).ready)
        XCTAssertTrue(FocusTransition.status(for: snap(editable: true, blocked: false)).ready)
    }

    #if DEBUG
    func testTheMeasureOverloadPassesInputBlockedThroughToo() {
        let status = FocusTransition.status(for: snap(blocked: true), measure: true, pointerGrant: 5)
        XCTAssertTrue(status.inputBlocked); XCTAssertTrue(status.measure); XCTAssertEqual(status.pointerGrant, 5)
    }
    #endif

    func testStatusChangesWhenOnlyInputBlockedChanges() {
        XCTAssertTrue(FocusTransition.statusChanged(previous: snap(blocked: false), next: snap(blocked: true)))
        XCTAssertTrue(FocusTransition.statusChanged(previous: snap(blocked: true), next: snap(blocked: false)))
        XCTAssertFalse(FocusTransition.statusChanged(previous: snap(blocked: true), next: snap(blocked: true)))
    }

    func testInputBlockedDoesNotCountAsGainingEditable() {
        XCTAssertFalse(FocusTransition.gainedEditable(previous: snap(editable: true, blocked: false), next: snap(blocked: true)))
    }
}

/// The pipeline reads the monitor's fresh snapshot; it has no parallel secure-field check of its own.
@MainActor
final class SecureFieldPipelineTests: XCTestCase {
    private final class Poster: EventPosting {
        var batches = 0
        func post(_ events: [CGEvent]) { batches += 1 }
    }

    private final class Controller: InputSourceControlling {
        func currentID() -> String { InputSourceSwitcher.asciiID }
        func select(_ id: String) -> Bool { true }
    }

    private final class Gate { var blocked = false }

    private func makePipeline(
        reader: ScriptedFocusReader, gate: Gate, poster: Poster, acks: @escaping @MainActor (Ack) -> Void
    ) -> EventPipeline {
        let environment = FocusEnvironment(
            trusted: { true }, frontmost: { (42, "TextEdit") }, ownPID: 1, inputBlocked: { gate.blocked })
        let monitor = FocusMonitor(reader: reader, environment: environment)
        return EventPipeline(
            snapshot: { await monitor.refreshNow() },
            switcher: InputSourceSwitcher(controller: Controller(), composition: nil, settle: { _ in }),
            injector: TextInjector(poster: poster),
            sendAck: acks,
            noteValidEvent: {}
        )
    }

    private func event(_ kind: EventKind, epoch: UInt64) -> KeyboardEvent {
        KeyboardEvent(
            protocolVersion: KeyboardEvent.currentVersion, eventId: UUID(), sessionId: UUID(), seq: 1, focusEpoch: epoch, kind: kind)
    }

    func testTextWhileBlockedGetsNoFocusAndInjectsNothing() async {
        let gate = Gate()
        gate.blocked = true
        let poster = Poster()
        var acks: [Ack] = []
        let pipeline = makePipeline(
            reader: ScriptedFocusReader([FocusFixtures.elementA]), gate: gate, poster: poster, acks: { acks.append($0) })
        await pipeline.process(event(.text("x"), epoch: 1))
        await pipeline.process(event(.backspace, epoch: 1))
        await pipeline.process(event(.returnKey, epoch: 1))
        XCTAssertEqual(acks.map(\.result), [.noFocus, .noFocus, .noFocus])
        XCTAssertEqual(poster.batches, 0)
    }

    func testFocusTurningSecureBetweenFirstReadAndInjectionInjectsNothing() async {
        let gate = Gate()
        let poster = Poster()
        var acks: [Ack] = []
        // First read: a normal field. Every later read: the same element, now a secure field (not editable).
        let secure = FocusReadResult(element: FocusFixtures.elementA.element, editable: false, secure: true)
        let reader = ScriptedFocusReader([FocusFixtures.elementA, secure])
        let pipeline = makePipeline(reader: reader, gate: gate, poster: poster, acks: { acks.append($0) })
        await pipeline.process(event(.text("x"), epoch: 1))
        XCTAssertGreaterThanOrEqual(reader.readCount, 2, "the late re-check really read again")
        XCTAssertEqual(poster.batches, 0)
        XCTAssertEqual(acks.map(\.result), [.noFocus])
    }

    func testUnblockedTextIsInjectedAsControl() async {
        let gate = Gate()
        let poster = Poster()
        var acks: [Ack] = []
        let reader = ScriptedFocusReader([FocusFixtures.elementA])
        let pipeline = makePipeline(reader: reader, gate: gate, poster: poster, acks: { acks.append($0) })
        await pipeline.process(event(.text("x"), epoch: 1))
        XCTAssertEqual(acks.map(\.result), [.posted], "control: unblocked text is injected")
        XCTAssertEqual(poster.batches, 1)
    }
}
