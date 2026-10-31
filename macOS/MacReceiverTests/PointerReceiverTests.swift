import CryptoKit
import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

@MainActor
final class PointerOutputSpy: PointerOutput {
    private(set) var actions: [PointerAction] = []
    func apply(_ actions: [PointerAction]) { self.actions += actions }
    func clear() { actions.removeAll() }
}

/// A `PointerReceiver` on a spy output, a manual clock and a recording log, with the iPhone's channel set of the same
/// handshake to seal packets against it.
@MainActor
final class PointerRig {
    let output = PointerOutputSpy()
    let defaults: UserDefaults
    let phone: ChannelSet
    let mac: ChannelSet
    var now: UInt64 = 1_000_000
    var activity = 0
    var logLines: [String] = []
    var grantChanges = 0
    var nextGrant: UInt32 = 1_000
    private(set) var receiver: PointerReceiver!

    init(enabled: Bool? = nil) {
        let suite = "rk.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        if let enabled { defaults.set(enabled, forKey: PointerReceiver.enabledKey) }
        let pairKey = SymmetricKey(data: Data(repeating: 7, count: 32))
        var macHandshake = MacHandshake(pairKey: pairKey, macNonce: Data(repeating: 1, count: 16))
        var phoneHandshake = PhoneHandshake(pairKey: pairKey, phoneNonce: Data(repeating: 2, count: 16))
        guard case .send(let hello) = macHandshake.begin(), case .send(let reply) = phoneHandshake.receive(hello),
              case .authenticated(let auth) = macHandshake.receive(reply), phoneHandshake.receive(auth) == .authenticated,
              let mac = macHandshake.takeChannelSet(), let phone = phoneHandshake.takeChannelSet()
        else { fatalError("handshake") }
        self.mac = mac
        self.phone = phone
        receiver = PointerReceiver(
            defaults: defaults, output: output, clock: { [unowned self] in now },
            makeGrant: { [unowned self] in
                defer { nextGrant += 1 }
                return nextGrant
            },
            noteActivity: { [unowned self] in activity += 1 },
            log: { [unowned self] in logLines.append($0) })
        receiver.onGrantChange = { [unowned self] in grantChanges += 1 }
    }

    /// Authenticated and open, the normal state while the touchpad page is shown.
    func openChannel() {
        receiver.attach(mac)
        XCTAssertEqual(receiver.handleOpen(grant: receiver.grant ?? 0), .posted)
        output.clear()
    }

    func send(_ payload: PointerPayload) {
        let packet = try! phone.sealer(.pointer).seal(payload.encode())
        receiver.handle(packet)
    }

    func move(dx: Int16, dy: Int16 = 0, buttons: UInt8 = 0, seq: UInt16 = 0) -> PointerPayload {
        PointerPayload(opcode: .move, buttons: buttons, dx: dx, dy: dy, dt: 160, buttonSeq: seq)
    }

    func buttonState(down: Bool, seq: UInt16) -> PointerPayload {
        PointerPayload(opcode: .buttonState, buttons: down ? 1 : 0, dx: 0, dy: 0, dt: 0, buttonSeq: seq)
    }

    func heartbeat(down: Bool, seq: UInt16) -> PointerPayload {
        PointerPayload(opcode: .heartbeat, buttons: down ? 1 : 0, dx: 0, dy: 0, dt: 0, buttonSeq: seq)
    }
}

@MainActor
final class PointerReceiverTests: XCTestCase {
    // MARK: Switch and grant

    func testTheSwitchIsOnByDefaultAndFollowsTheStoredValue() {
        XCTAssertTrue(PointerRig().receiver.isEnabled)
        XCTAssertFalse(PointerRig(enabled: false).receiver.isEnabled)
        XCTAssertTrue(PointerRig(enabled: true).receiver.isEnabled)
    }

    func testTurningTheSwitchStoresIt() {
        let rig = PointerRig()
        rig.receiver.setEnabled(false)
        XCTAssertEqual(rig.defaults.object(forKey: PointerReceiver.enabledKey) as? Bool, false)
        rig.receiver.setEnabled(true)
        XCTAssertEqual(rig.defaults.object(forKey: PointerReceiver.enabledKey) as? Bool, true)
    }

    func testAnAuthenticatedConnectionGetsAGrantAndOnlyWhileTheSwitchIsOn() {
        let on = PointerRig()
        XCTAssertNil(on.receiver.grant, "no grant before a connection is authenticated")
        on.receiver.attach(on.mac)
        XCTAssertEqual(on.receiver.grant, 1_000)

        let off = PointerRig(enabled: false)
        off.receiver.attach(off.mac)
        XCTAssertNil(off.receiver.grant)
    }

    func testEveryNewConnectionAndEveryTurningOnGivesANewGrant() {
        let rig = PointerRig()
        rig.receiver.attach(rig.mac)
        let first = rig.receiver.grant
        rig.receiver.detach()
        XCTAssertNil(rig.receiver.grant)
        rig.receiver.attach(rig.mac)
        let second = rig.receiver.grant
        XCTAssertNotEqual(first, second)
        rig.receiver.setEnabled(false)
        rig.receiver.setEnabled(true)
        XCTAssertNotNil(rig.receiver.grant)
        XCTAssertNotEqual(rig.receiver.grant, second)
        XCTAssertEqual(rig.grantChanges, 2, "off and on each tell the status to follow; attach does not (the first status is next)")
    }

    // MARK: Open and close

    func testOpenNeedsAnAuthenticatedConnection() {
        let rig = PointerRig()
        XCTAssertEqual(rig.receiver.handleOpen(grant: 1_000), .notAuthorized)
        XCTAssertFalse(rig.receiver.isOpen)
    }

    func testOpenNeedsTheSwitchOn() {
        let rig = PointerRig()
        rig.receiver.attach(rig.mac)
        let grant = rig.receiver.grant!
        rig.receiver.setEnabled(false)
        XCTAssertEqual(rig.receiver.handleOpen(grant: grant), .notAuthorized)
        XCTAssertFalse(rig.receiver.isOpen)
    }

    func testOpenNeedsTheCurrentGrant() {
        let rig = PointerRig()
        rig.receiver.attach(rig.mac)
        XCTAssertEqual(rig.receiver.handleOpen(grant: 999), .notAuthorized)
        XCTAssertFalse(rig.receiver.isOpen)
        // A grant from before the switch went off and on again is refused as well.
        let old = rig.receiver.grant!
        rig.receiver.setEnabled(false)
        rig.receiver.setEnabled(true)
        XCTAssertEqual(rig.receiver.handleOpen(grant: old), .notAuthorized)
        XCTAssertEqual(rig.receiver.handleOpen(grant: rig.receiver.grant!), .posted)
        XCTAssertTrue(rig.receiver.isOpen)
    }

    func testPacketsAreIgnoredUntilTheChannelIsOpen() {
        let rig = PointerRig()
        rig.receiver.attach(rig.mac)
        rig.send(rig.move(dx: 160))
        XCTAssertEqual(rig.output.actions, [])
        XCTAssertEqual(rig.activity, 0)
    }

    func testPacketsAreIgnoredWhenTheSwitchIsOffEvenIfTheChannelWasOpen() {
        let rig = PointerRig()
        rig.openChannel()
        rig.receiver.setEnabled(false)
        rig.output.clear()
        rig.send(rig.move(dx: 160))
        XCTAssertEqual(rig.output.actions, [])
        XCTAssertFalse(rig.receiver.isOpen)
    }

    func testPacketsAreIgnoredWithoutAnAuthenticatedConnection() {
        let rig = PointerRig()
        rig.openChannel()
        rig.receiver.detach()
        rig.output.clear()
        rig.send(rig.move(dx: 160))
        XCTAssertEqual(rig.output.actions, [])
    }

    func testCloseLetsGoOfEverythingAndStopsTheChannel() {
        let rig = PointerRig()
        rig.openChannel()
        rig.send(rig.buttonState(down: true, seq: 1))
        rig.send(PointerPayload(opcode: .scroll, buttons: 1, dx: 0, dy: 160, dt: 160, arg: 1, buttonSeq: 1))
        rig.output.clear()
        XCTAssertEqual(rig.receiver.handleClose(), .posted)
        XCTAssertEqual(rig.output.actions, [.leftButton(down: false), .scroll(dx: 0, dy: 0, phase: .ended)])
        XCTAssertFalse(rig.receiver.isOpen)
        rig.output.clear()
        rig.send(rig.move(dx: 160))
        XCTAssertEqual(rig.output.actions, [])
    }

    func testTheSwitchGoingOffReleasesAHeldButton() {
        let rig = PointerRig()
        rig.openChannel()
        rig.send(rig.buttonState(down: true, seq: 1))
        rig.output.clear()
        rig.receiver.setEnabled(false)
        XCTAssertEqual(rig.output.actions, [.leftButton(down: false)])
        XCTAssertNil(rig.receiver.grant)
    }

    func testALostConnectionReleasesAHeldButtonAndEndsAScroll() {
        let rig = PointerRig()
        rig.openChannel()
        rig.send(rig.buttonState(down: true, seq: 1))
        rig.send(PointerPayload(opcode: .scroll, buttons: 1, dx: 0, dy: 160, dt: 160, arg: 1, buttonSeq: 1))
        rig.output.clear()
        rig.receiver.detach()
        XCTAssertEqual(rig.output.actions, [.leftButton(down: false), .scroll(dx: 0, dy: 0, phase: .ended)])
        XCTAssertFalse(rig.receiver.isOpen)
    }

    func testShutdownReleasesToo() {
        let rig = PointerRig()
        rig.openChannel()
        rig.send(rig.buttonState(down: true, seq: 1))
        rig.output.clear()
        rig.receiver.shutdown()
        XCTAssertEqual(rig.output.actions, [.leftButton(down: false)])
    }

    func testANewSessionStartsFromNothing() {
        let rig = PointerRig()
        rig.openChannel()
        rig.send(rig.buttonState(down: true, seq: 1))
        XCTAssertEqual(rig.receiver.handleClose(), .posted)
        XCTAssertEqual(rig.receiver.handleOpen(grant: rig.receiver.grant!), .posted)
        rig.output.clear()
        rig.send(rig.buttonState(down: true, seq: 1))
        XCTAssertEqual(rig.output.actions, [.leftButton(down: true)], "seq 1 of the new page is not older than seq 1 of the last one")
    }

    // MARK: Packets

    func testAValidMovePacketReachesTheOutputAndCountsAsActivity() {
        let rig = PointerRig()
        rig.openChannel()
        rig.send(rig.move(dx: 256, dy: 0))
        guard case .move(let dx, let dy, let dragging)? = rig.output.actions.first, rig.output.actions.count == 1
        else { return XCTFail("\(rig.output.actions)") }
        XCTAssertGreaterThan(dx, 16)
        XCTAssertEqual(dy, 0)
        XCTAssertFalse(dragging)
        XCTAssertEqual(rig.activity, 1)
    }

    func testActivityIsReportedAtMostOncePerSecond() {
        let rig = PointerRig()
        rig.openChannel()
        for _ in 0..<5 {
            rig.send(rig.move(dx: 16))
            rig.now += 100_000
        }
        XCTAssertEqual(rig.activity, 1)
        rig.now += 1_000_000
        rig.send(rig.move(dx: 16))
        XCTAssertEqual(rig.activity, 2)
    }

    func testOlderButtonSeqDoesNotOverwriteANewerStateThroughTheWholePath() {
        let rig = PointerRig()
        rig.openChannel()
        rig.send(rig.buttonState(down: true, seq: 2))
        rig.output.clear()
        rig.send(rig.buttonState(down: false, seq: 1))
        XCTAssertEqual(rig.output.actions, [])
    }

    func testWatchdogReleasesAfter350MillisecondsAndALateHeartbeatDoesNotPressAgain() {
        let rig = PointerRig()
        rig.openChannel()
        rig.send(rig.buttonState(down: true, seq: 1))
        rig.output.clear()
        rig.now += 349_000
        rig.receiver.watchdogTick()
        XCTAssertEqual(rig.output.actions, [])
        rig.now += 1_000
        rig.receiver.watchdogTick()
        XCTAssertEqual(rig.output.actions, [.leftButton(down: false)])
        rig.output.clear()
        rig.send(rig.heartbeat(down: true, seq: 1))
        XCTAssertEqual(rig.output.actions, [])
    }

    func testAForgedOrReplayedPacketDoesNothing() throws {
        let rig = PointerRig()
        rig.openChannel()
        let packet = try rig.phone.sealer(.pointer).seal(rig.move(dx: 160).encode())
        var forged = packet
        forged[12] ^= 0x01
        rig.receiver.handle(forged)
        XCTAssertEqual(rig.output.actions, [])
        rig.receiver.handle(packet)
        XCTAssertEqual(rig.output.actions.count, 1)
        rig.receiver.handle(packet)
        XCTAssertEqual(rig.output.actions.count, 1, "the same packet twice moves once")
    }

    func testAValidEnvelopeWithAnUnreadablePayloadIsDropped() throws {
        let rig = PointerRig()
        rig.openChannel()
        var bytes = [UInt8](rig.move(dx: 160).encode())
        bytes[1] |= 0x04
        let packet = try rig.phone.sealer(.pointer).seal(Data(bytes))
        rig.receiver.handle(packet)
        XCTAssertEqual(rig.output.actions, [])
        XCTAssertTrue(rig.receiver.isOpen, "one bad payload does not close the channel")
    }

    func testEightFailuresInARowCloseTheChannelAndAGoodPacketResetsTheCount() throws {
        let rig = PointerRig()
        rig.openChannel()
        let garbage = Data([0x03]) + Data(repeating: 9, count: 40)
        for _ in 0..<7 { rig.receiver.handle(garbage) }
        XCTAssertTrue(rig.receiver.isOpen)
        rig.send(rig.move(dx: 16))
        for _ in 0..<7 { rig.receiver.handle(garbage) }
        XCTAssertTrue(rig.receiver.isOpen, "a good packet in between started the count again")
        rig.receiver.handle(garbage)
        XCTAssertFalse(rig.receiver.isOpen)
    }

    // MARK: Log

    func testTheLogNeverHoldsCoordinatesOrDisplacements() {
        let rig = PointerRig()
        rig.openChannel()
        rig.send(rig.move(dx: 12_345, dy: -23_456))
        rig.send(rig.buttonState(down: true, seq: 1))
        rig.send(PointerPayload(opcode: .scroll, buttons: 1, dx: 8_765, dy: -9_876, dt: 160, arg: 1, buttonSeq: 1))
        rig.receiver.watchdogTick()
        rig.now += 400_000
        rig.receiver.watchdogTick()
        _ = rig.receiver.handleClose()
        rig.receiver.detach()
        let log = rig.logLines.joined(separator: "\n")
        XCTAssertFalse(rig.logLines.isEmpty, "the events themselves are logged")
        for forbidden in ["12345", "23456", "8765", "9876", "12_345", "771", "-1466", "dx", "dy", "x=", "y=", "x:", "y:"] {
            XCTAssertFalse(log.contains(forbidden), "\(forbidden) in \(log)")
        }
    }
}
