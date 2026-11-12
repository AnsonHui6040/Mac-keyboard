import CryptoKit
import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

/// The Mac side of T09: handshake, pairing window, session pin and what is written back, all against a recording
/// radio and an in-memory key store. Nothing here touches Bluetooth or the Keychain.
@MainActor
final class ReceiverSecurityTests: XCTestCase {
    private let key = SymmetricKey(data: Data(repeating: 0x11, count: 32))
    private let otherKey = SymmetricKey(data: Data(repeating: 0x22, count: 32))
    private let otherHostId = Data(repeating: 0xEE, count: 16)

    private func status(_ epoch: UInt64 = 3) -> ControlMessage {
        .status(ReceiverStatus(ready: true, appName: "Notes", focusEpoch: epoch))
    }

    // MARK: Handshake

    func testUnpairedPeripheralIsDisconnectedAndSkippedForSession() throws {
        let rig = SecurityRig(pairKey: key)
        let stranger = TestPhone(pairKey: otherKey)
        rig.connect()
        try rig.authenticate(stranger)

        XCTAssertEqual(rig.driver.writes.filter { $0 == .authFailed }.count, 1, "the failure is told to the peripheral, in the clear, once")
        XCTAssertEqual(rig.driver.writes.last, .authFailed)
        XCTAssertEqual(rig.cancels, [rig.peripheral], "and the connection is dropped")
        XCTAssertTrue(rig.events.isEmpty)
        XCTAssertEqual(rig.authenticatedCount, 0)

        // The same identifier is not connected to again while this receiving session lasts.
        rig.driver.calls.removeAll()
        rig.central.handleLink(.discovered(rig.peripheral))
        XCTAssertFalse(rig.driver.calls.contains(.connect(rig.peripheral)), "skipped for the rest of the receiving session")
        let another = UUID()
        rig.central.handleLink(.discovered(another))
        XCTAssertTrue(rig.driver.calls.contains(.connect(another)), "other peripherals are not affected")
    }

    func testSkipEndsWhenTheReceivingSessionEnds() throws {
        let rig = SecurityRig(pairKey: key)
        rig.connect()
        try rig.authenticate(TestPhone(pairKey: otherKey))
        rig.central.stopReceiving()
        rig.central.startReceiving()
        rig.driver.calls.removeAll()
        rig.central.handleLink(.discovered(rig.peripheral))
        XCTAssertTrue(rig.driver.calls.contains(.connect(rig.peripheral)), "a new receiving session starts with an empty skip list")
    }

    func testMacWithNoPairKeyRefusesWithoutSayingHello() {
        let rig = SecurityRig(pairKey: nil)
        rig.connect()
        XCTAssertEqual(rig.newWrites(), [.authFailed], "no challenge is issued; there is nobody to verify against")
        XCTAssertEqual(rig.cancels, [rig.peripheral])
        rig.driver.calls.removeAll()
        rig.central.handleLink(.discovered(rig.peripheral))
        XCTAssertFalse(rig.driver.calls.contains(.connect(rig.peripheral)))
    }

    func testPairedPhoneAuthenticatesAndItsEventsReachTheHandler() throws {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        let session = UUID()
        rig.connect()
        let outputs = try rig.authenticate(phone)
        XCTAssertEqual(outputs, [.authenticated])
        XCTAssertEqual(rig.security.connectedPhoneName, TestIdentity.phone().name, "the panel shows who is connected")
        XCTAssertEqual(rig.authenticatedCount, 1)
        XCTAssertTrue(rig.security.isAuthenticated)

        let message = try phone.sealed(.text("A"), session: session, seq: 1)
        try rig.deliver(message, from: phone)
        XCTAssertEqual(rig.events.count, 1)
        XCTAssertEqual(rig.events.first?.kind, .text("A"))
        XCTAssertTrue(rig.cancels.isEmpty)
    }

    func testEachConnectionOpensWithAFreshNonce() throws {
        let rig = SecurityRig(pairKey: key)
        rig.connect()
        guard case .hello(_, let first)? = rig.newWrites().first else { return XCTFail("no hello") }
        rig.central.handleLink(.disconnected(rig.peripheral))
        rig.central.handleLink(.rescanTimer)
        rig.central.handleLink(.discovered(rig.peripheral))
        rig.central.handleLink(.connected(rig.peripheral))
        rig.central.handleLink(.linkReady(rig.peripheral))
        guard case .hello(_, let second)? = rig.newWrites().first else { return XCTFail("no second hello") }
        XCTAssertEqual(first.count, Pairing.nonceLength)
        XCTAssertNotEqual(first, second)
    }

    func testPlaintextEventFailsAuthAndDisconnects() throws {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        rig.connect()
        try rig.authenticate(phone)
        _ = rig.newWrites()

        let event = KeyboardEvent(
            protocolVersion: KeyboardEvent.currentVersion, eventId: UUID(), sessionId: UUID(), seq: 1, focusEpoch: 3, kind: .text("secret"))
        try rig.deliver(.event(event), from: phone)

        XCTAssertTrue(rig.events.isEmpty, "a plaintext event never reaches the pipeline")
        XCTAssertEqual(rig.newWrites(), [.authFailed])
        XCTAssertEqual(rig.cancels, [rig.peripheral])
        rig.driver.calls.removeAll()
        rig.central.handleLink(.discovered(rig.peripheral))
        XCTAssertFalse(rig.driver.calls.contains(.connect(rig.peripheral)))
    }

    func testPlaintextEventBeforeAuthFailsToo() throws {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        rig.connect()
        let event = KeyboardEvent(
            protocolVersion: KeyboardEvent.currentVersion, eventId: UUID(), sessionId: UUID(), seq: 1, focusEpoch: 3, kind: .backspace)
        try rig.deliver(.event(event), from: phone)
        XCTAssertTrue(rig.events.isEmpty)
        XCTAssertEqual(rig.cancels, [rig.peripheral])
    }

    func testBytesThatAreNotAMessageFailAuth() {
        let rig = SecurityRig(pairKey: key)
        rig.connect()
        for frame in (try? FrameCodec.split(Data("not json".utf8), messageId: 1, maxFrameBytes: 182)) ?? [] {
            rig.central.receive(eventData: frame)
        }
        XCTAssertEqual(rig.cancels, [rig.peripheral])
        XCTAssertTrue(rig.events.isEmpty)
    }

    func testSessionIdChangeOnAuthenticatedLinkFails() throws {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        let first = UUID()
        rig.connect()
        try rig.authenticate(phone)
        try rig.deliver(try phone.sealed(.text("A"), session: first, seq: 1), from: phone)
        try rig.deliver(try phone.sealed(.text("B"), session: first, seq: 2), from: phone)
        XCTAssertEqual(rig.events.count, 2, "the pinned session keeps working")
        _ = rig.newWrites()

        try rig.deliver(try phone.sealed(.text("C"), session: UUID(), seq: 1), from: phone)
        XCTAssertEqual(rig.events.count, 2, "an event of another session never reaches the pipeline")
        XCTAssertEqual(rig.newWrites(), [.authFailed])
        XCTAssertEqual(rig.cancels, [rig.peripheral])
    }

    func testTamperedSealedEventFailsAuth() throws {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        rig.connect()
        try rig.authenticate(phone)
        guard case .sealed(var payload) = try phone.sealed(.text("A"), session: UUID()) else { return XCTFail() }
        payload[payload.count - 1] ^= 0x01
        try rig.deliver(.sealed(payload), from: phone)
        XCTAssertTrue(rig.events.isEmpty)
        XCTAssertEqual(rig.cancels, [rig.peripheral])
    }

    func testAnEventSealedForAnotherConnectionFailsAuth() throws {
        let rig = SecurityRig(pairKey: key)
        let old = TestPhone(pairKey: key)
        rig.connect()
        try rig.authenticate(old)
        let recorded = try old.sealed(.text("A"), session: UUID())
        rig.central.handleLink(.disconnected(rig.peripheral))
        rig.central.handleLink(.rescanTimer)
        rig.central.handleLink(.discovered(rig.peripheral))
        rig.central.handleLink(.connected(rig.peripheral))
        rig.central.handleLink(.linkReady(rig.peripheral))
        let fresh = TestPhone(pairKey: key)
        try rig.authenticate(fresh)
        try rig.deliver(recorded, from: fresh)
        XCTAssertTrue(rig.events.isEmpty, "a recorded event from the earlier connection does not open under the new session key")
        XCTAssertEqual(rig.cancels.count, 1)
    }

    func testAuthenticatedButUnparsableEventIsAnsweredMalformedNotDropped() throws {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        rig.connect()
        try rig.authenticate(phone)
        // A sealed payload that opens but is not a PeripheralMessage.
        let crypto = SessionCrypto(pairKey: key, hostNonce: rig.lastHostNonce, phoneNonce: phone.nonce, direction: .phoneToMac)
        try rig.deliver(.sealed(try crypto.seal(Data("{}".utf8))), from: phone)
        XCTAssertEqual(rig.malformed, 1)
        XCTAssertTrue(rig.cancels.isEmpty, "a decrypted but malformed payload is not an authentication failure")
    }

    func testHandshakeTimeoutDisconnectsASilentPeripheral() async throws {
        let rig = SecurityRig(pairKey: key, handshakeTimeout: 0.05)
        rig.connect()
        XCTAssertTrue(rig.cancels.isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(rig.cancels, [rig.peripheral], "a peripheral that never answers hello is dropped")
    }

    func testHandshakeTimeoutWritesNoAuthFailed() {
        let rig = SecurityRig(pairKey: key)
        rig.connect()
        XCTAssertEqual(rig.newWrites().count, 1, "only the hello")
        rig.security.handshakeTimerFired()
        XCTAssertEqual(rig.cancels, [rig.peripheral], "the connection is dropped")
        XCTAssertTrue(rig.newWrites().isEmpty, "and nothing is written to the control characteristic: no authFailed")
        XCTAssertNil(rig.security.updatePhoneNote)
        XCTAssertEqual(rig.linkLostCount, 1)
    }

    func testHandshakeTimeoutDoesNotSkipPeripheral() {
        let rig = SecurityRig(pairKey: key)
        rig.connect()
        rig.security.handshakeTimerFired()
        rig.driver.calls.removeAll()
        rig.central.handleLink(.discovered(rig.peripheral))
        XCTAssertFalse(rig.driver.calls.contains(.connect(rig.peripheral)), "held off for 10 seconds, only this device")
        let another = UUID()
        rig.central.handleLink(.discovered(another))
        XCTAssertTrue(rig.driver.calls.contains(.connect(another)), "the search for others goes on")
        rig.central.handleLink(.disconnected(another))

        rig.now = rig.now.addingTimeInterval(ReceiverLinkStateMachine.handshakeBackoffSeconds + 1)
        rig.central.handleLink(.rescanTimer)
        rig.driver.calls.removeAll()
        rig.central.handleLink(.discovered(rig.peripheral))
        XCTAssertTrue(rig.driver.calls.contains(.connect(rig.peripheral)), "seen again after the back-off: connected again, not skipped for the session")
    }

    func testAuthenticatedLinkIsNotTimedOutByTheTimerEither() throws {
        let rig = SecurityRig(pairKey: key)
        rig.connect()
        try rig.authenticate(TestPhone(pairKey: key))
        rig.security.handshakeTimerFired()
        XCTAssertTrue(rig.cancels.isEmpty)
    }

    func testNotSelectedBacksOffWithoutErrorAndWithoutSkipping() throws {
        let rig = SecurityRig(pairKey: key)
        let elsewhere = TestPhone(pairKey: key, hostId: otherHostId)
        rig.connect()
        let hello = try XCTUnwrap(rig.newWrites().first)
        guard case .send(let reply) = elsewhere.handshake.receive(hello) else { return XCTFail("the phone must answer notSelected") }
        XCTAssertEqual(reply, .notSelected)
        try rig.deliver(reply, from: elsewhere)

        XCTAssertEqual(rig.cancels, [rig.peripheral], "the connection ends")
        XCTAssertTrue(rig.newWrites().isEmpty, "no authFailed")
        XCTAssertNil(rig.security.updatePhoneNote)
        XCTAssertNil(rig.security.lastResult, "no error is shown")
        XCTAssertEqual(rig.authenticatedCount, 0)
        rig.driver.calls.removeAll()
        rig.central.handleLink(.discovered(rig.peripheral))
        XCTAssertFalse(rig.driver.calls.contains(.connect(rig.peripheral)), "10 seconds off for this device")
        rig.now = rig.now.addingTimeInterval(ReceiverLinkStateMachine.handshakeBackoffSeconds + 1)
        rig.central.handleLink(.discovered(rig.peripheral))
        XCTAssertTrue(rig.driver.calls.contains(.connect(rig.peripheral)), "then it is connectable again")
    }

    // MARK: Protocol version

    private func v3Bytes() -> Data { Data(#"{"protocolVersion":3,"type":"pairOffer","commitment":"AAAA"}"#.utf8) }

    func testUnsupportedVersionShowsUpdatePhoneNote() throws {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        rig.connect()
        XCTAssertNil(rig.security.updatePhoneNote)
        for frame in try phone.frames(raw: v3Bytes()) { rig.central.receive(eventData: frame) }
        XCTAssertEqual(rig.security.updatePhoneNote, "請更新 iPhone App")
        XCTAssertFalse(rig.newWrites().contains(.authFailed), "a version mismatch is not an authentication failure")
    }

    func testUnsupportedVersionDisconnectsAndHoldsFor60Seconds() throws {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        rig.connect()
        for frame in try phone.frames(raw: v3Bytes()) { rig.central.receive(eventData: frame) }
        XCTAssertEqual(rig.cancels, [rig.peripheral])
        XCTAssertEqual(rig.linkLostCount, 1)

        rig.driver.calls.removeAll()
        rig.now = rig.now.addingTimeInterval(ReceiverLinkStateMachine.unsupportedVersionHoldSeconds - 1)
        rig.central.handleLink(.discovered(rig.peripheral))
        XCTAssertFalse(rig.driver.calls.contains(.connect(rig.peripheral)), "not within 60 seconds")
        let another = UUID()
        rig.central.handleLink(.discovered(another))
        XCTAssertTrue(rig.driver.calls.contains(.connect(another)), "only this device is held")
        rig.central.handleLink(.disconnected(another))

        rig.now = rig.now.addingTimeInterval(2)
        rig.central.handleLink(.rescanTimer)
        rig.driver.calls.removeAll()
        rig.central.handleLink(.discovered(rig.peripheral))
        XCTAssertTrue(rig.driver.calls.contains(.connect(rig.peripheral)), "after 60 seconds it may connect again")
    }

    func testUnsupportedVersionInsideThePairingWindowIsNotHeld() throws {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        rig.security.openPairingWindow()
        rig.connect(route: .pairing)
        for frame in try phone.frames(raw: v3Bytes()) { rig.central.receive(eventData: frame) }
        XCTAssertEqual(rig.security.updatePhoneNote, "請更新 iPhone App", "the note is shown all the same")
        XCTAssertEqual(rig.cancels, [rig.peripheral])
        XCTAssertEqual(rig.security.phase, .waiting, "the window stays open")
        rig.driver.calls.removeAll()
        rig.central.handleLink(.discovered(rig.peripheral), route: .pairing)
        XCTAssertTrue(rig.driver.calls.contains(.connect(rig.peripheral)), "it may be the phone the user is about to pair (docs/protocol/v4.md §6.2)")
    }

    func testTheUpdateNoteGoesAwayOnceAPhoneAuthenticates() throws {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        rig.connect()
        for frame in try phone.frames(raw: v3Bytes()) { rig.central.receive(eventData: frame) }
        XCTAssertNotNil(rig.security.updatePhoneNote)
        _ = rig.newWrites()
        rig.central.handleLink(.disconnected(rig.peripheral))
        rig.now = rig.now.addingTimeInterval(ReceiverLinkStateMachine.unsupportedVersionHoldSeconds + 1)
        rig.central.handleLink(.discovered(rig.peripheral))
        rig.central.handleLink(.connected(rig.peripheral))
        rig.central.handleLink(.linkReady(rig.peripheral))
        try rig.authenticate(TestPhone(pairKey: key))
        XCTAssertNil(rig.security.updatePhoneNote)
    }

    // MARK: Several phones

    func testSecondPairedPhoneAuthenticates() throws {
        let first = PairedPhone(identity: TestIdentity.phone(1), pairKey: key)
        let second = PairedPhone(identity: TestIdentity.phone(2), pairKey: otherKey)
        let rig = SecurityRig(phones: [first, second])
        let phone = TestPhone(pairKey: otherKey, identity: second.identity)
        rig.connect()
        let outputs = try rig.authenticate(phone)
        XCTAssertEqual(outputs, [.authenticated], "the host does not know who answers; it tries every key")
        XCTAssertEqual(rig.authenticatedCount, 1)
        XCTAssertEqual(rig.security.connectedPhoneName, second.identity.name)
        XCTAssertTrue(rig.cancels.isEmpty)
        try rig.deliver(try phone.sealed(.text("A"), session: UUID()), from: phone)
        XCTAssertEqual(rig.events.first?.kind, .text("A"), "events open under the second phone's key")
    }

    func testPairingAdvertConnectionSendsNoHello() throws {
        let rig = SecurityRig(pairKey: key)
        rig.security.openPairingWindow()
        rig.connect(route: .pairing)
        XCTAssertTrue(rig.newWrites().isEmpty, "a connection found through the pairing UUID waits for pairOffer, even with a key stored")
        XCTAssertTrue(rig.cancels.isEmpty)
        // The phone speaks first.
        let p = PairingPhone()
        try rig.deliver(p.pairing.offer, from: p.phone)
        guard case .pairAccept(_, let host)? = rig.newWrites().first else { return XCTFail("no pairAccept") }
        XCTAssertEqual(host, TestIdentity.host)
    }

    func testPairingRouteConnectionOutsideTheWindowIsDropped() {
        let rig = SecurityRig(pairKey: key)
        rig.connect(route: .pairing)
        XCTAssertTrue(rig.newWrites().isEmpty)
        XCTAssertEqual(rig.cancels, [rig.peripheral])
        XCTAssertEqual(rig.security.phase, .idle)
    }

    func testPairingRouteConnectionThatSaysNothingTimesOutLikeAHandshake() {
        let rig = SecurityRig(pairKey: key)
        rig.security.openPairingWindow()
        rig.connect(route: .pairing)
        rig.security.handshakeTimerFired()
        XCTAssertEqual(rig.cancels, [rig.peripheral])
        XCTAssertTrue(rig.newWrites().isEmpty, "no authFailed")
        XCTAssertEqual(rig.security.phase, .waiting)
    }

    func testPairingRouteRefusesHelloReplyAndSelectedRouteRefusesPairOffer() throws {
        let rig = SecurityRig(pairKey: key)
        rig.security.openPairingWindow()
        rig.connect(route: .pairing)
        let phone = TestPhone(pairKey: key)
        try rig.deliver(.helloReply(phoneNonce: phone.nonce, proof: Data(repeating: 0, count: 32)), from: phone)
        XCTAssertEqual(rig.newWrites(), [.authFailed], "a helloReply on a pairing connection is an authentication failure")

        let second = SecurityRig(pairKey: key)
        second.security.openPairingWindow()
        second.connect()
        _ = second.newWrites()
        let p = PairingPhone()
        try second.deliver(p.pairing.offer, from: p.phone)
        XCTAssertEqual(second.newWrites(), [.authFailed], "a pairOffer on a connection found through the selected UUID is too")
        XCTAssertEqual(second.security.phase, .waiting)
    }

    func testRemovingTheConnectedPhoneSaysByeAndDisconnects() throws {
        let first = PairedPhone(identity: TestIdentity.phone(1), pairKey: key)
        let second = PairedPhone(identity: TestIdentity.phone(2), pairKey: otherKey)
        let rig = SecurityRig(phones: [first, second])
        let phone = TestPhone(pairKey: otherKey, identity: second.identity)
        rig.connect()
        try rig.authenticate(phone)
        rig.answerOutstandingWrites()
        _ = rig.newWrites()

        rig.security.removePhone(id: second.identity.id)
        XCTAssertEqual(rig.store.phones.map(\.identity), [first.identity])
        XCTAssertEqual(rig.security.phones, [first.identity])
        XCTAssertNil(rig.security.connectedPhoneName)
        let writes = rig.newWrites()
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(phone.handshake.receive(writes[0]), .deliver(.bye), "protocol §7.4: a sealed bye before the disconnect")
        rig.answerOutstandingWrites()
        XCTAssertEqual(rig.cancels, [rig.peripheral])
    }

    func testRemovingAnotherPhoneLeavesTheConnectionAlone() throws {
        let first = PairedPhone(identity: TestIdentity.phone(1), pairKey: key)
        let second = PairedPhone(identity: TestIdentity.phone(2), pairKey: otherKey)
        let rig = SecurityRig(phones: [first, second])
        let phone = TestPhone(pairKey: key, identity: first.identity)
        rig.connect()
        try rig.authenticate(phone)
        rig.answerOutstandingWrites()
        _ = rig.newWrites()
        rig.security.removePhone(id: second.identity.id)
        XCTAssertEqual(rig.store.phones.map(\.identity), [first.identity])
        XCTAssertTrue(rig.newWrites().isEmpty)
        XCTAssertTrue(rig.cancels.isEmpty)
        XCTAssertTrue(rig.security.isAuthenticated)
        XCTAssertEqual(rig.security.connectedPhoneName, first.identity.name)
    }

    func testOpeningTheWindowWithEightPhonesIsRefusedBeforeAnythingStarts() {
        let phones = (1...8).map { PairedPhone(identity: TestIdentity.phone(UInt8($0)), pairKey: SymmetricKey(size: .bits256)) }
        let rig = SecurityRig(phones: phones)
        rig.security.openPairingWindow()
        XCTAssertEqual(rig.security.phase, .idle, "no window")
        XCTAssertEqual(rig.security.lastResult, .full)
        XCTAssertFalse(rig.central.isArmed, "receiving was not turned on for it")
        XCTAssertEqual(PairingSheet.resultText(.full), "已配對 8 支手機，請先刪除一支")
    }

    func testAddedDateIsWrittenTheTaiwanWay() {
        let date = Date(timeIntervalSince1970: 1_794_000_000) // 2026-11-07 05:20 in Taipei
        XCTAssertEqual(PairingSheet.addedText(date, timeZone: TimeZone(identifier: "Asia/Taipei")!), "配對於 2026/11/07")
    }

    func testPairingScanConditionFollowsTheWindow() {
        let rig = SecurityRig(pairKey: nil)
        let select = SelectUUID.make(hostId: TestIdentity.hostId)
        let pairing = UUID(uuidString: GATTServiceSpec.Link.pairingAdvertUUID)!
        rig.central.startReceiving()
        rig.central.handleLink(.power(.poweredOn))
        XCTAssertEqual(rig.driver.scans.last, [select])
        rig.security.openPairingWindow()
        XCTAssertEqual(rig.driver.scans.last, [select, pairing], "the pairing UUID is scanned while the window is open")
        rig.security.cancelPairing()
        XCTAssertEqual(rig.driver.scans.last, [select], "and the condition is reset the moment the window closes")
    }

    func testAuthenticatedLinkIsNotTimedOut() async throws {
        let rig = SecurityRig(pairKey: key, handshakeTimeout: 0.05)
        let phone = TestPhone(pairKey: key)
        rig.connect()
        try rig.authenticate(phone)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(rig.cancels.isEmpty)
    }

    // MARK: Control writes

    func testNothingIsWrittenBeforeAuthExceptTheHandshake() throws {
        let rig = SecurityRig(pairKey: key)
        rig.connect()
        rig.security.send(status())
        rig.security.send(.ack(Ack(eventId: UUID(), result: .posted)))
        XCTAssertEqual(rig.newWrites().count, 1, "only hello; a status or ack before auth is dropped, app name included")
        XCTAssertFalse(rig.driver.controlWrites.contains { String(decoding: $0, as: UTF8.self).contains("Notes") })
    }

    func testEveryControlWriteAfterAuthIsSealed() throws {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        rig.connect()
        try rig.authenticate(phone)
        let authWrites = rig.bytesWritten()

        rig.security.send(status())
        rig.security.send(.ack(Ack(eventId: UUID(), result: .posted)))
        rig.security.send(status(4))
        let after = rig.driver.controlWrites.dropFirst(authWrites)
        XCTAssertEqual(after.count, 3)
        for data in after {
            guard case .sealed = try ControlCodec.decode(data) else { return XCTFail("a control write after auth is not sealed") }
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Notes"), "the app name is not in the clear")
        }
        // And the phone can read them.
        var delivered: [ControlMessage] = []
        for data in after { if case .deliver(let m) = phone.receive(data) { delivered.append(m) } }
        XCTAssertEqual(delivered.count, 3)
        XCTAssertEqual(delivered.first, status())
    }

    func testPlainAckOrStatusIsNeverWrittenEvenAfterAuth() throws {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        rig.connect()
        try rig.authenticate(phone)
        rig.security.send(.authFailed)
        rig.security.send(.hello(hostId: TestIdentity.hostId, hostNonce: Data(count: 16)))
        XCTAssertTrue(rig.newWrites().isEmpty, "only ack and status go through send, and only sealed")
    }

    // MARK: Pairing

    /// A pairing connection: the window is open and the peripheral was found through the pairing UUID.
    private func openWindowAndConnect(_ rig: SecurityRig) {
        rig.security.openPairingWindow()
        rig.connect(route: .pairing)
    }

    @MainActor private struct PairingPhone {
        var pairing = PhonePairing(privateKey: P256.KeyAgreement.PrivateKey(), phone: TestIdentity.phone(5))
        let phone = TestPhone(pairKey: nil)
    }

    private func runPairingUntilSAS(_ rig: SecurityRig, _ p: inout PairingPhone) throws {
        try rig.deliver(p.pairing.offer, from: p.phone)
        let accept = try XCTUnwrap(rig.newWrites().first)
        guard case .send(let reveal) = p.pairing.receive(accept) else { return XCTFail("phone did not reveal") }
        try rig.deliver(reveal, from: p.phone)
    }

    /// Continues from an offer that has already been delivered.
    private func runPairingUntilSASAfterOffer(_ rig: SecurityRig, _ p: inout PairingPhone) throws {
        let accept = try XCTUnwrap(rig.newWrites().first)
        guard case .send(let reveal) = p.pairing.receive(accept) else { return XCTFail("phone did not reveal") }
        try rig.deliver(reveal, from: p.phone)
    }

    func testPairOfferIgnoredAfterTheWindowExpired() throws {
        let rig = SecurityRig(pairKey: key)
        let p = PairingPhone()
        rig.security.openPairingWindow()
        rig.connect(route: .pairing)
        _ = rig.newWrites()
        rig.now = rig.now.addingTimeInterval(PairingWindow.duration + 1)
        try rig.deliver(p.pairing.offer, from: p.phone)
        XCTAssertTrue(rig.newWrites().isEmpty)
        XCTAssertEqual(rig.cancels, [rig.peripheral])
        XCTAssertEqual(rig.store.saves, 0)
        rig.driver.calls.removeAll()
        rig.central.handleLink(.discovered(rig.peripheral))
        XCTAssertFalse(rig.driver.calls.contains(.connect(rig.peripheral)), "a phone that keeps offering is not connected in a loop")
    }

    func testPairKeyStoredOnlyAfterConfirm() throws {
        let rig = SecurityRig(pairKey: nil)
        var p = PairingPhone()
        openWindowAndConnect(rig)
        try runPairingUntilSAS(rig, &p)

        guard case .confirming(let sas) = rig.security.phase else { return XCTFail("expected the SAS prompt") }
        XCTAssertEqual(sas, p.pairing.sas, "both sides show the same six digits")
        XCTAssertEqual(sas.count, 6)
        XCTAssertEqual(rig.store.saves, 0, "nothing is stored while the prompt is open")
        XCTAssertTrue(rig.store.loadPhones().isEmpty)
        XCTAssertEqual(rig.security.pairingPhoneName, TestIdentity.phone(5).name, "the prompt says whose pairing it is")

        rig.security.confirmPairing()
        XCTAssertEqual(rig.store.saves, 1)
        XCTAssertEqual(rig.store.loadPhones().first?.identity, TestIdentity.phone(5), "the phone is stored with the identity it revealed")
        XCTAssertEqual(rig.security.phones, [TestIdentity.phone(5)])
        XCTAssertEqual(rig.security.phase, .confirmed)
        XCTAssertTrue(rig.security.isPaired)
        XCTAssertEqual(rig.security.lastResult, .paired)
    }

    func testConfirmKeepsTheLinkSoTheOtherSideCanStillConfirm() throws {
        let rig = SecurityRig(pairKey: nil)
        var p = PairingPhone()
        openWindowAndConnect(rig)
        try runPairingUntilSAS(rig, &p)
        rig.security.confirmPairing()
        XCTAssertTrue(rig.cancels.isEmpty, "the connection stays up after this side confirmed")
        XCTAssertTrue(rig.central.isArmed)
        // Nothing the phone sends now disturbs the stored result.
        try rig.deliver(p.pairing.offer, from: p.phone)
        XCTAssertEqual(rig.security.phase, .confirmed)
        XCTAssertEqual(rig.store.saves, 1)
        // A second tap on 確認 stores nothing more.
        rig.security.confirmPairing()
        XCTAssertEqual(rig.store.saves, 1)
    }

    func testFinishEndsTheWindowAndDropsTheLink() throws {
        let rig = SecurityRig(pairKey: nil)
        var p = PairingPhone()
        openWindowAndConnect(rig)
        try runPairingUntilSAS(rig, &p)
        rig.security.confirmPairing()
        rig.security.finishPairing()
        XCTAssertEqual(rig.security.phase, .idle)
        XCTAssertEqual(rig.security.lastResult, .paired)
        XCTAssertFalse(rig.cancels.isEmpty)
        XCTAssertFalse(rig.central.isArmed, "receiving that pairing started ends with it")
    }

    func testThePhoneLeavingAfterConfirmCompletesThePairing() throws {
        let rig = SecurityRig(pairKey: nil)
        var p = PairingPhone()
        openWindowAndConnect(rig)
        try runPairingUntilSAS(rig, &p)
        rig.security.confirmPairing()
        rig.central.handleLink(.disconnected(rig.peripheral))
        XCTAssertEqual(rig.security.phase, .idle)
        XCTAssertEqual(rig.security.lastResult, .paired, "not a failure: the key was stored and stays stored")
        XCTAssertEqual(rig.store.saves, 1)
        XCTAssertEqual(rig.store.loadPhones().count, 1)
    }

    func testWindowExpiryAfterConfirmKeepsTheStoredKey() throws {
        let rig = SecurityRig(pairKey: nil)
        var p = PairingPhone()
        openWindowAndConnect(rig)
        try runPairingUntilSAS(rig, &p)
        rig.security.confirmPairing()
        rig.now = rig.now.addingTimeInterval(PairingWindow.duration + 1)
        rig.security.windowTimerFired()
        XCTAssertEqual(rig.security.phase, .idle)
        XCTAssertEqual(rig.security.lastResult, .paired)
        XCTAssertEqual(rig.store.loadPhones().count, 1)
    }

    func testStoredPairKeyIsTheOneBothSidesDerived() throws {
        let rig = SecurityRig(pairKey: nil)
        var p = PairingPhone()
        openWindowAndConnect(rig)
        try runPairingUntilSAS(rig, &p)
        rig.security.confirmPairing()
        let stored = try XCTUnwrap(rig.store.loadPhones().first).pairKey
        let phoneKey = try XCTUnwrap(p.pairing.pairKey)
        let probe = Data(repeating: 7, count: 16)
        XCTAssertEqual(Pairing.phoneProof(key: stored, hostNonce: probe, phoneNonce: probe),
                       Pairing.phoneProof(key: phoneKey, hostNonce: probe, phoneNonce: probe))
    }

    func testCancelStoresNothingAndDisconnects() throws {
        let rig = SecurityRig(pairKey: nil)
        var p = PairingPhone()
        openWindowAndConnect(rig)
        try runPairingUntilSAS(rig, &p)
        rig.security.cancelPairing()
        XCTAssertEqual(rig.store.saves, 0)
        XCTAssertTrue(rig.store.loadPhones().isEmpty)
        XCTAssertEqual(rig.security.phase, .idle)
        XCTAssertEqual(rig.security.lastResult, .cancelled)
        XCTAssertFalse(rig.cancels.isEmpty)
        XCTAssertFalse(rig.security.isPaired)
    }

    func testStoreFailureReportsRealPairedState() throws {
        let rig = SecurityRig(pairKey: nil)
        var p = PairingPhone()
        rig.store.failSave = true
        openWindowAndConnect(rig)
        try runPairingUntilSAS(rig, &p)
        rig.security.confirmPairing()
        XCTAssertEqual(rig.security.lastResult, .storeFailed)
        XCTAssertFalse(rig.security.isPaired)
        XCTAssertEqual(rig.security.phase, .idle)
    }

    func testStoreFailureKeepsTheOtherPhonesAndShowsTheStoreAsItIs() throws {
        let rig = SecurityRig(pairKey: key)
        var p = PairingPhone()
        rig.store.failSave = true
        rig.security.openPairingWindow()
        rig.connect(route: .pairing)
        try runPairingUntilSAS(rig, &p)
        XCTAssertTrue(rig.security.isPaired)
        rig.security.confirmPairing()
        XCTAssertEqual(rig.security.lastResult, .storeFailed)
        XCTAssertEqual(rig.store.loadPhones().count, 1, "the phone that was paired before is untouched")
        XCTAssertEqual(rig.security.phones.count, 1, "the panel lists what the store holds")
    }

    func testWindowExpiryDoesNotDropAnAuthenticatedKeyboard() throws {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        rig.central.startReceiving()
        rig.security.openPairingWindow()
        rig.connect()
        try rig.authenticate(phone)
        rig.now = rig.now.addingTimeInterval(PairingWindow.duration + 1)
        rig.security.windowTimerFired()
        XCTAssertEqual(rig.security.phase, .idle)
        XCTAssertTrue(rig.cancels.isEmpty, "the keyboard that is typing is not the pairing connection")
        XCTAssertTrue(rig.central.isArmed)
        XCTAssertTrue(rig.security.isAuthenticated)
        let message = try phone.sealed(.text("A"), session: UUID())
        try rig.deliver(message, from: phone)
        XCTAssertEqual(rig.events.count, 1)
    }

    func testCancelDoesNotStopReceivingWhileAKeyboardIsAuthenticated() throws {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        XCTAssertFalse(rig.central.isArmed)
        rig.security.openPairingWindow()       // arms receiving
        rig.connect()
        try rig.authenticate(phone)
        rig.security.cancelPairing()
        XCTAssertTrue(rig.central.isArmed, "an authenticated keyboard keeps the receiving session alive")
        XCTAssertTrue(rig.cancels.isEmpty)
    }

    func testConfirmWithoutASASPromptStoresNothing() {
        let rig = SecurityRig(pairKey: nil)
        rig.security.confirmPairing()
        rig.security.openPairingWindow()
        rig.security.confirmPairing()
        XCTAssertEqual(rig.store.saves, 0)
    }

    func testWindowTimeoutDiscardsAnUnconfirmedAttempt() throws {
        let rig = SecurityRig(pairKey: nil)
        var p = PairingPhone()
        openWindowAndConnect(rig)
        try runPairingUntilSAS(rig, &p)
        rig.now = rig.now.addingTimeInterval(PairingWindow.duration + 1)
        rig.security.windowTimerFired()
        XCTAssertEqual(rig.security.phase, .idle)
        XCTAssertEqual(rig.security.lastResult, .timedOut)
        rig.security.confirmPairing()
        XCTAssertEqual(rig.store.saves, 0, "a late tap on 確認 stores nothing")
        XCTAssertFalse(rig.cancels.isEmpty)
    }

    func testWindowTimerBeforeTheDeadlineChangesNothing() {
        let rig = SecurityRig(pairKey: nil)
        rig.security.openPairingWindow()
        rig.now = rig.now.addingTimeInterval(30)
        rig.security.windowTimerFired()
        XCTAssertEqual(rig.security.phase, .waiting)
    }

    func testRevealThatDoesNotMatchTheCommitmentDiscardsEverything() throws {
        let rig = SecurityRig(pairKey: nil)
        var p = PairingPhone()
        openWindowAndConnect(rig)
        try rig.deliver(p.pairing.offer, from: p.phone)
        _ = rig.newWrites()
        let attacker = Pairing.publicKeyData(P256.KeyAgreement.PrivateKey())
        try rig.deliver(.pairReveal(publicKey: attacker, phone: TestIdentity.phone(5)), from: p.phone)
        XCTAssertEqual(rig.security.phase, .idle)
        XCTAssertEqual(rig.security.lastResult, .failed)
        XCTAssertEqual(rig.store.saves, 0)
        XCTAssertFalse(rig.cancels.isEmpty)
        _ = p
    }

    func testEveryPairingAttemptUsesAFreshMacKey() throws {
        var accepted: [Data] = []
        for _ in 0..<2 {
            let rig = SecurityRig(pairKey: nil)
            let p = PairingPhone()
            openWindowAndConnect(rig)
            try rig.deliver(p.pairing.offer, from: p.phone)
            guard case .pairAccept(let publicKey, _)? = rig.newWrites().first else { return XCTFail("no pairAccept") }
            accepted.append(publicKey)
        }
        // Two attempts on one security object, without reopening everything.
        let rig = SecurityRig(pairKey: nil)
        openWindowAndConnect(rig)
        let first = PairingPhone()
        try rig.deliver(first.pairing.offer, from: first.phone)
        guard case .pairAccept(let a, _)? = rig.newWrites().first else { return XCTFail("no pairAccept") }
        rig.security.cancelPairing()
        rig.central.handleLink(.disconnected(rig.peripheral))
        rig.central.handleLink(.rescanTimer)
        rig.driver.calls.removeAll()
        openWindowAndConnect(rig)
        let second = PairingPhone()
        try rig.deliver(second.pairing.offer, from: second.phone)
        guard case .pairAccept(let b, _)? = rig.newWrites().first else { return XCTFail("no second pairAccept") }
        accepted += [a, b]
        XCTAssertEqual(Set(accepted).count, 4, "no Mac key is ever offered twice")
    }

    func testSecondOfferDuringAnAttemptFailsTheAttempt() throws {
        let rig = SecurityRig(pairKey: nil)
        let p = PairingPhone()
        openWindowAndConnect(rig)
        try rig.deliver(p.pairing.offer, from: p.phone)
        _ = rig.newWrites()
        try rig.deliver(p.pairing.offer, from: p.phone)
        XCTAssertEqual(rig.security.phase, .idle)
        XCTAssertEqual(rig.store.saves, 0)
    }

    func testLinkLostDuringAnAttemptDiscardsIt() throws {
        let rig = SecurityRig(pairKey: nil)
        var p = PairingPhone()
        openWindowAndConnect(rig)
        try runPairingUntilSAS(rig, &p)
        rig.central.handleLink(.disconnected(rig.peripheral))
        XCTAssertEqual(rig.security.phase, .idle)
        XCTAssertEqual(rig.security.lastResult, .failed)
        rig.security.confirmPairing()
        XCTAssertEqual(rig.store.saves, 0)
    }

    func testAuthFailureOnANonPairingConnectionInsideTheWindowDoesNotSkipThePeripheral() {
        let rig = SecurityRig(pairKey: key)
        rig.security.openPairingWindow()
        rig.connect()
        for frame in (try? FrameCodec.split(Data("not json".utf8), messageId: 1, maxFrameBytes: 182)) ?? [] {
            rig.central.receive(eventData: frame)
        }
        XCTAssertEqual(rig.cancels, [rig.peripheral])
        XCTAssertEqual(rig.security.phase, .waiting, "the window stays open")
        rig.driver.calls.removeAll()
        rig.central.handleLink(.discovered(rig.peripheral))
        XCTAssertTrue(rig.driver.calls.contains(.connect(rig.peripheral)), "the same iPhone can still pair inside the window")
    }

    func testSilentPeripheralIsDroppedInsideTheWaitingWindowAndMayTryAgainAfterTheBackOff() {
        let rig = SecurityRig(pairKey: nil)
        openWindowAndConnect(rig)
        rig.security.handshakeTimerFired()
        XCTAssertEqual(rig.cancels, [rig.peripheral], "a peripheral that never offers does not hold the only connection")
        XCTAssertEqual(rig.security.phase, .waiting, "the window stays open")
        XCTAssertTrue(rig.newWrites().isEmpty, "and nothing is written to it")
        rig.driver.calls.removeAll()
        rig.central.handleLink(.discovered(rig.peripheral), route: .pairing)
        XCTAssertFalse(rig.driver.calls.contains(.connect(rig.peripheral)), "10 seconds off, like any handshake timeout")
        rig.now = rig.now.addingTimeInterval(ReceiverLinkStateMachine.handshakeBackoffSeconds + 1)
        rig.central.handleLink(.discovered(rig.peripheral), route: .pairing)
        XCTAssertTrue(rig.driver.calls.contains(.connect(rig.peripheral)), "and then it is not skipped")
    }

    func testHandshakeTimerLeavesAnAttemptInProgressAlone() throws {
        let rig = SecurityRig(pairKey: nil)
        var p = PairingPhone()
        openWindowAndConnect(rig)
        try rig.deliver(p.pairing.offer, from: p.phone)
        rig.security.handshakeTimerFired()
        XCTAssertTrue(rig.cancels.isEmpty, "an offer was made: the window's own deadline bounds it")
        try runPairingUntilSASAfterOffer(rig, &p)
        rig.security.handshakeTimerFired()
        XCTAssertTrue(rig.cancels.isEmpty, "confirming")
        rig.security.confirmPairing()
        rig.security.handshakeTimerFired()
        XCTAssertTrue(rig.cancels.isEmpty, "confirmed")
        XCTAssertEqual(rig.security.phase, .confirmed)
    }

    func testLinkLostWhileOnlyWaitingKeepsTheWindowOpen() throws {
        let rig = SecurityRig(pairKey: nil)
        openWindowAndConnect(rig)
        rig.central.handleLink(.disconnected(rig.peripheral))
        XCTAssertEqual(rig.security.phase, .waiting)
    }

    func testOpeningTheWindowArmsReceivingAndClosingItStopsWhatItArmed() {
        let rig = SecurityRig(pairKey: nil)
        XCTAssertFalse(rig.central.isArmed)
        rig.security.openPairingWindow()
        XCTAssertTrue(rig.central.isArmed)
        rig.security.cancelPairing()
        XCTAssertFalse(rig.central.isArmed, "receiving that pairing started ends with it")

        rig.central.startReceiving()
        rig.security.openPairingWindow()
        rig.security.cancelPairing()
        XCTAssertTrue(rig.central.isArmed, "receiving that was already on stays on")
    }

    func testOpeningTheWindowClearsTheSkipListAndRescans() throws {
        let rig = SecurityRig(pairKey: key)
        rig.connect()
        try rig.authenticate(TestPhone(pairKey: otherKey))
        rig.driver.calls.removeAll()
        rig.security.openPairingWindow()
        XCTAssertTrue(rig.driver.calls.contains(.startScan), "a fresh scan, so a phone seen before is reported again")
        rig.driver.calls.removeAll()
        rig.central.handleLink(.discovered(rig.peripheral))
        XCTAssertTrue(rig.driver.calls.contains(.connect(rig.peripheral)))
    }

    // MARK: Unpair

    func testRemovingThePhoneDeletesTheKeyAndDropsTheLink() throws {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        rig.connect()
        try rig.authenticate(phone)
        XCTAssertTrue(rig.security.isPaired)
        rig.answerOutstandingWrites()
        _ = rig.newWrites()
        rig.security.removePhone(id: TestIdentity.phone().id)
        XCTAssertTrue(rig.store.loadPhones().isEmpty)
        XCTAssertFalse(rig.security.isPaired)
        XCTAssertFalse(rig.security.isAuthenticated)
        XCTAssertEqual(rig.newWrites().count, 1, "the goodbye, sealed, is the last thing the keyboard hears")
        rig.answerOutstandingWrites()
        XCTAssertEqual(rig.cancels, [rig.peripheral], "an authenticated link does not outlive the pairing")
        rig.security.send(status())
        XCTAssertEqual(rig.newWrites().count, 0)
    }

    func testRevokedPhoneCannotAuthenticateAgain() throws {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        rig.connect()
        try rig.authenticate(phone)
        rig.security.removePhone(id: TestIdentity.phone().id)
        rig.answerOutstandingWrites()
        rig.central.handleLink(.rescanTimer)
        rig.central.handleLink(.discovered(rig.peripheral))
        rig.central.handleLink(.connected(rig.peripheral))
        rig.central.handleLink(.linkReady(rig.peripheral))
        XCTAssertEqual(rig.newWrites().last, .authFailed, "a Mac with no pairing refuses at once")
        XCTAssertTrue(rig.events.isEmpty)
    }
}
