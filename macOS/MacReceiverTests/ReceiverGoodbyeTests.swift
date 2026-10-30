import CryptoKit
import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

/// Every deliberate end of an authenticated connection says a sealed `bye` first and cancels only after the write
/// response (or half a second). A connection that never authenticated is cancelled at once, as before.
@MainActor
final class ReceiverGoodbyeTests: XCTestCase {
    private let key = SymmetricKey(data: Data(repeating: 0x11, count: 32))

    private func authenticatedRig() throws -> (SecurityRig, TestPhone) {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        rig.connect()
        try rig.authenticate(phone)
        _ = rig.newWrites()
        rig.answerOutstandingWrites()  // the hello and the auth were answered long ago
        return (rig, phone)
    }

    /// Plays one control write on the phone side and returns what the keyboard would deliver.
    private func delivered(_ write: ControlMessage, to phone: TestPhone) throws -> PhoneHandshakeOutput {
        phone.handshake.receive(write)
    }

    // MARK: Manual stop

    func testManualStopSendsSealedByeBeforeCancel() throws {
        let (rig, phone) = try authenticatedRig()
        rig.central.stopReceiving()

        let writes = rig.newWrites()
        XCTAssertEqual(writes.count, 1, "exactly one control write: the goodbye")
        guard case .sealed? = writes.first else { return XCTFail("the goodbye must be sealed, never plain") }
        XCTAssertEqual(try delivered(writes[0], to: phone), .deliver(.bye))
        XCTAssertTrue(rig.cancels.isEmpty, "the connection stays up until the write is answered")
        XCTAssertFalse(rig.central.isArmed)
        XCTAssertEqual(rig.central.linkState, .idle)

        rig.central.controlWriteCompleted()
        XCTAssertEqual(rig.cancels, [rig.peripheral], "cancelled after the write response")
    }

    func testByeBytesAreNotReadable() throws {
        let (rig, _) = try authenticatedRig()
        rig.central.stopReceiving()
        let wire = try XCTUnwrap(rig.driver.controlWrites.last)
        XCTAssertNil(String(decoding: wire, as: UTF8.self).range(of: "bye"))
    }

    // MARK: Cancel timing

    func testCancelHappensAfterWriteResponseOrHalfSecond() async throws {
        XCTAssertEqual(ReceiverBLECentral.goodbyeTimeout, 0.5)

        // Response first: no waiting.
        let (fast, _) = try authenticatedRig()
        fast.central.stopReceiving()
        XCTAssertTrue(fast.cancels.isEmpty)
        fast.central.controlWriteCompleted()
        XCTAssertEqual(fast.cancels, [fast.peripheral])

        // No response: the half-second fallback cancels, not earlier.
        let (slow, _) = try authenticatedRig()
        slow.central.stopReceiving()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertTrue(slow.cancels.isEmpty, "still waiting for the write response at 0.25 s")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(slow.cancels, [slow.peripheral], "cancelled by the 0.5 s fallback")

        // A late response after the fallback changes nothing.
        slow.central.controlWriteCompleted()
        XCTAssertEqual(slow.cancels, [slow.peripheral])
    }

    func testEarlierWriteResponseDoesNotReleaseTheGoodbye() throws {
        let (rig, _) = try authenticatedRig()
        rig.security.send(.status(ReceiverStatus(ready: true, appName: "Notes", focusEpoch: 2)))
        rig.central.stopReceiving()
        XCTAssertEqual(rig.newWrites().count, 2, "the status and the goodbye are two writes in a row")
        rig.central.controlWriteCompleted()
        XCTAssertTrue(rig.cancels.isEmpty, "the first response belongs to the status write, not the goodbye")
        rig.central.controlWriteCompleted()
        XCTAssertEqual(rig.cancels, [rig.peripheral])
    }

    // MARK: Unauthenticated

    func testUnauthenticatedStopCancelsWithoutBye() {
        let rig = SecurityRig(pairKey: key)
        rig.connect()
        _ = rig.newWrites()  // the hello
        rig.central.stopReceiving()
        XCTAssertEqual(rig.newWrites(), [], "a link that never authenticated gets no goodbye")
        XCTAssertEqual(rig.cancels, [rig.peripheral], "and is cancelled at once")
    }

    func testUnauthenticatedUnpairCancelsWithoutBye() {
        let rig = SecurityRig(pairKey: key)
        rig.connect()
        _ = rig.newWrites()
        rig.security.unpair()
        XCTAssertEqual(rig.newWrites(), [])
        XCTAssertEqual(rig.cancels, [rig.peripheral])
    }

    func testFailedAuthenticationCancelsWithoutBye() throws {
        let rig = SecurityRig(pairKey: key)
        rig.connect()
        try rig.authenticate(TestPhone(pairKey: SymmetricKey(data: Data(repeating: 0x22, count: 32))))
        XCTAssertEqual(rig.newWrites().filter { $0 != .authFailed && $0 != .hello(macNonce: rig.lastMacNonce) }.count, 0)
        XCTAssertEqual(rig.cancels, [rig.peripheral])
    }

    // MARK: Idle timeout and unpair

    func testIdleTimeoutAndUnpairSendBye() throws {
        // Idle timeout.
        let (idle, idlePhone) = try authenticatedRig()
        idle.now = idle.now.addingTimeInterval(ReceiverSession.idleTimeout + 1)
        idle.central.handleSession(.timerFired)
        XCTAssertFalse(idle.central.isArmed)
        let idleWrites = idle.newWrites()
        XCTAssertEqual(idleWrites.count, 1)
        XCTAssertEqual(try delivered(idleWrites[0], to: idlePhone), .deliver(.bye))
        XCTAssertTrue(idle.cancels.isEmpty)
        idle.central.controlWriteCompleted()
        XCTAssertEqual(idle.cancels, [idle.peripheral])

        // Unpair.
        let (unpair, unpairPhone) = try authenticatedRig()
        unpair.security.unpair()
        let unpairWrites = unpair.newWrites()
        XCTAssertEqual(unpairWrites.count, 1)
        XCTAssertEqual(try delivered(unpairWrites[0], to: unpairPhone), .deliver(.bye))
        XCTAssertNil(unpair.store.load())
        XCTAssertFalse(unpair.security.isAuthenticated)
        XCTAssertTrue(unpair.cancels.isEmpty)
        unpair.central.controlWriteCompleted()
        XCTAssertEqual(unpair.cancels, [unpair.peripheral])
        // Nothing else is ever written to the unpaired link.
        unpair.security.send(.status(ReceiverStatus(ready: true, appName: nil, focusEpoch: 1)))
        XCTAssertEqual(unpair.newWrites(), [])
    }

    func testOpeningThePairingWindowSaysByeToTheConnectedKeyboard() throws {
        let (rig, phone) = try authenticatedRig()
        rig.security.openPairingWindow()
        let writes = rig.newWrites()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(try delivered(writes[0], to: phone), .deliver(.bye))
    }

    // MARK: Phone-side failures do not say goodbye

    func testLinkLostByThePhoneNeverWritesBye() throws {
        let (rig, _) = try authenticatedRig()
        rig.central.handleLink(.disconnected(rig.peripheral))
        XCTAssertEqual(rig.newWrites(), [])
        let (invalid, _) = try authenticatedRig()
        invalid.central.handleLink(.serviceInvalidated(invalid.peripheral))
        XCTAssertEqual(invalid.newWrites(), [], "a service the phone changed is not a deliberate disconnect")
        XCTAssertEqual(invalid.cancels, [invalid.peripheral], "and is cancelled at once")
    }

    // MARK: Restart inside the goodbye window

    func testDiscoveryInsideTheGoodbyeWindowIsRescannedAfterTheCancel() throws {
        let (rig, _) = try authenticatedRig()
        rig.central.stopReceiving()
        rig.central.startReceiving()
        rig.driver.calls.removeAll()
        rig.central.handleLink(.discovered(rig.peripheral))
        XCTAssertFalse(rig.driver.calls.contains(.connect(rig.peripheral)), "not while the old connection is being closed")

        rig.central.controlWriteCompleted()
        XCTAssertEqual(rig.driver.calls.first, .cancel(rig.peripheral))
        XCTAssertEqual(rig.driver.calls.last, .startScan, "a fresh scan reports the phone again")
        rig.central.handleLink(.discovered(rig.peripheral))
        XCTAssertTrue(rig.driver.calls.contains(.connect(rig.peripheral)))
    }

    // MARK: App termination

    func testTerminationSendsByeAndCancelsBeforeReturning() throws {
        let (rig, phone) = try authenticatedRig()
        rig.central.prepareForTermination()
        let writes = rig.newWrites()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(try delivered(writes[0], to: phone), .deliver(.bye))
        XCTAssertEqual(rig.cancels, [rig.peripheral], "the connection is closed by the time the app goes away")
    }

    func testTerminationWithNothingConnectedReturnsAtOnce() {
        let rig = SecurityRig(pairKey: key)
        let start = Date()
        rig.central.prepareForTermination()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.2)
        XCTAssertEqual(rig.cancels, [])
    }
}
