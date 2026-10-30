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
        guard case .hello(let first)? = rig.newWrites().first else { return XCTFail("no hello") }
        rig.central.handleLink(.disconnected(rig.peripheral))
        rig.central.handleLink(.rescanTimer)
        rig.central.handleLink(.discovered(rig.peripheral))
        rig.central.handleLink(.connected(rig.peripheral))
        rig.central.handleLink(.linkReady(rig.peripheral))
        guard case .hello(let second)? = rig.newWrites().first else { return XCTFail("no second hello") }
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
        let crypto = SessionCrypto(pairKey: key, macNonce: rig.lastMacNonce, phoneNonce: phone.nonce, direction: .phoneToMac)
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
        XCTAssertEqual(rig.newWrites().last, .authFailed)
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
        rig.security.send(.hello(macNonce: Data(count: 16)))
        XCTAssertTrue(rig.newWrites().isEmpty, "only ack and status go through send, and only sealed")
    }

    // MARK: Pairing

    private func openWindowAndConnect(_ rig: SecurityRig) {
        rig.security.openPairingWindow()
        rig.connect()
    }

    @MainActor private struct PairingPhone {
        var pairing = PhonePairing(privateKey: P256.KeyAgreement.PrivateKey())
        let phone = TestPhone(pairKey: nil)
    }

    private func runPairingUntilSAS(_ rig: SecurityRig, _ p: inout PairingPhone) throws {
        try rig.deliver(p.pairing.offer, from: p.phone)
        let accept = try XCTUnwrap(rig.newWrites().first)
        guard case .send(let reveal) = p.pairing.receive(accept) else { return XCTFail("phone did not reveal") }
        try rig.deliver(reveal, from: p.phone)
    }

    func testPairOfferIgnoredOutsidePairingWindow() throws {
        let rig = SecurityRig(pairKey: key)
        let p = PairingPhone()
        rig.connect()
        _ = rig.newWrites()
        try rig.deliver(p.pairing.offer, from: p.phone)
        XCTAssertTrue(rig.newWrites().isEmpty, "no pairAccept is written")
        XCTAssertEqual(rig.cancels, [rig.peripheral], "the peripheral is disconnected")
        XCTAssertEqual(rig.security.phase, .idle)
        XCTAssertEqual(rig.store.saves, 0)
        rig.driver.calls.removeAll()
        rig.central.handleLink(.discovered(rig.peripheral))
        XCTAssertFalse(rig.driver.calls.contains(.connect(rig.peripheral)), "and not reconnected in a loop")
    }

    func testPairOfferIgnoredAfterTheWindowExpired() throws {
        let rig = SecurityRig(pairKey: key)
        let p = PairingPhone()
        rig.security.openPairingWindow()
        rig.connect()
        _ = rig.newWrites()
        rig.now = rig.now.addingTimeInterval(PairingWindow.duration + 1)
        try rig.deliver(p.pairing.offer, from: p.phone)
        XCTAssertTrue(rig.newWrites().isEmpty)
        XCTAssertEqual(rig.cancels, [rig.peripheral])
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
        XCTAssertNil(rig.store.load())

        rig.security.confirmPairing()
        XCTAssertEqual(rig.store.saves, 1)
        XCTAssertNotNil(rig.store.load())
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
        XCTAssertNotNil(rig.store.load())
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
        XCTAssertNotNil(rig.store.load())
    }

    func testStoredPairKeyIsTheOneBothSidesDerived() throws {
        let rig = SecurityRig(pairKey: nil)
        var p = PairingPhone()
        openWindowAndConnect(rig)
        try runPairingUntilSAS(rig, &p)
        rig.security.confirmPairing()
        let stored = try XCTUnwrap(rig.store.load())
        let phoneKey = try XCTUnwrap(p.pairing.pairKey)
        let probe = Data(repeating: 7, count: 16)
        XCTAssertEqual(Pairing.phoneProof(key: stored, macNonce: probe, phoneNonce: probe),
                       Pairing.phoneProof(key: phoneKey, macNonce: probe, phoneNonce: probe))
    }

    func testCancelStoresNothingAndDisconnects() throws {
        let rig = SecurityRig(pairKey: nil)
        var p = PairingPhone()
        openWindowAndConnect(rig)
        try runPairingUntilSAS(rig, &p)
        rig.security.cancelPairing()
        XCTAssertEqual(rig.store.saves, 0)
        XCTAssertNil(rig.store.load())
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

    func testStoreFailureShowsTheStateOfTheStoreEvenWhenItLostTheOldKey() throws {
        let rig = SecurityRig(pairKey: key)
        var p = PairingPhone()
        rig.store.failSave = true
        rig.security.openPairingWindow()
        rig.connect()
        _ = rig.newWrites()
        try runPairingUntilSAS(rig, &p)
        XCTAssertTrue(rig.security.isPaired)
        rig.security.confirmPairing()
        XCTAssertEqual(rig.security.lastResult, .storeFailed)
        XCTAssertNil(rig.store.load(), "a failed save left no key (the real store deletes the old one first)")
        XCTAssertFalse(rig.security.isPaired, "the panel must not claim a pairing the store no longer has")
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
        try rig.deliver(.pairReveal(publicKey: attacker), from: p.phone)
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
            guard case .pairAccept(let publicKey)? = rig.newWrites().first else { return XCTFail("no pairAccept") }
            accepted.append(publicKey)
        }
        // Two attempts on one security object, without reopening everything.
        let rig = SecurityRig(pairKey: nil)
        openWindowAndConnect(rig)
        let first = PairingPhone()
        try rig.deliver(first.pairing.offer, from: first.phone)
        guard case .pairAccept(let a)? = rig.newWrites().first else { return XCTFail("no pairAccept") }
        rig.security.cancelPairing()
        rig.central.handleLink(.disconnected(rig.peripheral))
        rig.central.handleLink(.rescanTimer)
        rig.driver.calls.removeAll()
        openWindowAndConnect(rig)
        let second = PairingPhone()
        try rig.deliver(second.pairing.offer, from: second.phone)
        guard case .pairAccept(let b)? = rig.newWrites().first else { return XCTFail("no second pairAccept") }
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

    func testUnpairDeletesTheKeyAndDropsTheLink() throws {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        rig.connect()
        try rig.authenticate(phone)
        XCTAssertTrue(rig.security.isPaired)
        rig.security.unpair()
        XCTAssertNil(rig.store.load())
        XCTAssertFalse(rig.security.isPaired)
        XCTAssertEqual(rig.cancels, [rig.peripheral], "an authenticated link does not outlive the pairing")
        XCTAssertFalse(rig.security.isAuthenticated)
        rig.security.send(status())
        XCTAssertEqual(rig.newWrites().count, 0)
    }

    func testRevokedPhoneCannotAuthenticateAgain() throws {
        let rig = SecurityRig(pairKey: key)
        let phone = TestPhone(pairKey: key)
        rig.connect()
        try rig.authenticate(phone)
        rig.security.unpair()
        rig.central.handleLink(.rescanTimer)
        rig.central.handleLink(.discovered(rig.peripheral))
        rig.central.handleLink(.connected(rig.peripheral))
        rig.central.handleLink(.linkReady(rig.peripheral))
        XCTAssertEqual(rig.newWrites().last, .authFailed, "a Mac with no pairing refuses at once")
        XCTAssertTrue(rig.events.isEmpty)
    }
}
