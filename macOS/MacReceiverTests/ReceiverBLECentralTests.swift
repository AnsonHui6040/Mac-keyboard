import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

@MainActor
private final class FakeDriver: CentralDriving {
    enum Call: Equatable { case startScan, stopScan, connect(UUID), discover(UUID), cancel(UUID), forget(UUID) }
    var calls: [Call] = []
    var controlWrites: [Data] = []
    func writeControl(_ data: Data) { controlWrites.append(data) }
    func startScan() { calls.append(.startScan) }
    func stopScan() { calls.append(.stopScan) }
    func connect(_ id: UUID) { calls.append(.connect(id)) }
    func discover(_ id: UUID) { calls.append(.discover(id)) }
    func cancel(_ id: UUID) { calls.append(.cancel(id)) }
    func forget(_ id: UUID) { calls.append(.forget(id)) }
}

@MainActor
final class ReceiverBLECentralTests: XCTestCase {
    private var defaults: UserDefaults!
    private var driver: FakeDriver!
    private var madeDrivers = 0

    override func setUp() async throws {
        let name = "rk.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)
        defaults.removePersistentDomain(forName: name)
        driver = FakeDriver()
        madeDrivers = 0
    }

    private func make(
        clock: @escaping () -> Date = Date.init, monotonicMs: @escaping () -> Int64 = MonotonicClock.nowMs
    ) -> ReceiverBLECentral {
        ReceiverBLECentral(defaults: defaults, clock: clock, monotonicMs: monotonicMs) { [unowned self] _ in
            madeDrivers += 1
            return driver
        }
    }

    func testStaysIdleAndCreatesNoDriverUntilArmed() {
        let central = make()
        XCTAssertEqual(central.linkState, .idle)
        XCTAssertEqual(madeDrivers, 0)
        XCTAssertEqual(central.linkLabel, "Link: idle")
        XCTAssertNil(central.remainingSeconds)
    }

    func testManualStartArmsAndScansOncePowered() {
        let central = make()
        central.startReceiving()
        XCTAssertTrue(central.isArmed)
        XCTAssertEqual(madeDrivers, 1)
        central.handleLink(.power(.poweredOn))
        XCTAssertEqual(driver.calls, [.startScan])
        XCTAssertEqual(central.linkLabel, "Link: scanning")
    }

    func testReadyLabelCarriesMilliseconds() {
        let central = make()
        let p = UUID()
        central.startReceiving()
        central.handleLink(.power(.poweredOn))
        central.handleLink(.discovered(p))
        central.handleLink(.connected(p))
        central.handleLink(.linkReady(p))
        XCTAssertEqual(driver.calls, [.startScan, .stopScan, .connect(p), .discover(p)])
        XCTAssertTrue(central.linkLabel.hasPrefix("Link: ready ("))
        XCTAssertTrue(central.linkLabel.hasSuffix(" ms)"))
    }

    func testManualStopReturnsToIdleAndCancelsPeripheral() {
        let central = make()
        let p = UUID()
        central.startReceiving()
        central.handleLink(.power(.poweredOn))
        central.handleLink(.discovered(p))
        central.handleLink(.connected(p))
        central.handleLink(.linkReady(p))
        central.stopReceiving()
        XCTAssertFalse(central.isArmed)
        XCTAssertEqual(central.linkState, .idle)
        XCTAssertEqual(driver.calls.last, .cancel(p))
        XCTAssertNil(central.remainingSeconds)
    }

    func testIdleTimeoutOverrideDisarmsAfterFiring() async throws {
        defaults.set(0.05, forKey: ReceiverBLECentral.idleTimeoutKey)
        let central = make()
        central.startReceiving()
        XCTAssertTrue(central.isArmed)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(central.isArmed)
        XCTAssertEqual(central.linkState, .idle)
    }

    func testIdleTimerFiresWhileMenuTracking() {
        defaults.set(0.2, forKey: ReceiverBLECentral.idleTimeoutKey)
        let central = make()
        central.startReceiving()
        XCTAssertTrue(central.isArmed)
        // AppKit registers this mode as common in the running app; make that explicit for the test host.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))
        let end = Date().addingTimeInterval(1.0)
        while Date() < end && central.isArmed {
            RunLoop.main.run(mode: .eventTracking, before: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(central.isArmed)
    }

    func testReachingReadyExtendsDeadline() {
        var current = Date(timeIntervalSince1970: 1000)
        let central = make(clock: { current })
        let p = UUID()
        central.startReceiving()
        central.handleLink(.power(.poweredOn))
        central.handleLink(.discovered(p))
        central.handleLink(.connected(p))
        current = Date(timeIntervalSince1970: 1900)
        XCTAssertEqual(central.remainingSeconds, 900)
        central.handleLink(.linkReady(p))
        XCTAssertEqual(central.remainingSeconds, 1800)
        // Repeated events while already ready are not new connections.
        current = Date(timeIntervalSince1970: 2000)
        central.handleLink(.linkReady(p))
        XCTAssertEqual(central.remainingSeconds, 1700)
    }

    func testRemainingSecondsTracksClockWithoutTick() {
        var current = Date(timeIntervalSince1970: 1000)
        let central = make(clock: { current })
        central.startReceiving()
        current = Date(timeIntervalSince1970: 1100)
        XCTAssertEqual(central.remainingSeconds, 1700)
    }

    func testDefaultIdleTimeoutIsThirtyMinutes() {
        var current = Date(timeIntervalSince1970: 1000)
        let central = make(clock: { current })
        central.startReceiving()
        XCTAssertEqual(central.deadline, Date(timeIntervalSince1970: 2800))
        current = Date(timeIntervalSince1970: 1600)
        central.noteEvent()
        XCTAssertEqual(central.deadline, Date(timeIntervalSince1970: 3400))
    }

    func testRemainingTextFormat() {
        XCTAssertEqual(ReceiverMenu.remainingText(nil), "待命")
        XCTAssertEqual(ReceiverMenu.remainingText(1800), "剩餘接收時間 30:00")
        XCTAssertEqual(ReceiverMenu.remainingText(59.2), "剩餘接收時間 01:00")
        XCTAssertEqual(ReceiverMenu.remainingText(0), "剩餘接收時間 00:00")
    }

    // MARK: T05 wiring

    private func makeReady(_ central: ReceiverBLECentral) -> UUID {
        let p = UUID()
        central.startReceiving()
        central.handleLink(.power(.poweredOn))
        central.handleLink(.discovered(p))
        central.handleLink(.connected(p))
        central.handleLink(.linkReady(p))
        return p
    }

    func testControlWriteIsDroppedUntilLinkIsReady() {
        let central = make()
        central.startReceiving()
        central.send(.status(ReceiverStatus(ready: true, appName: "TextEdit", focusEpoch: 1)))
        XCTAssertEqual(driver.controlWrites, [])
    }

    func testControlWriteGoesToDriverOnceReadyAndDecodes() throws {
        let central = make()
        _ = makeReady(central)
        let status = ControlMessage.status(ReceiverStatus(ready: true, appName: "TextEdit", focusEpoch: 9))
        central.send(status)
        XCTAssertEqual(driver.controlWrites.count, 1)
        XCTAssertEqual(try ControlCodec.decode(driver.controlWrites[0]), status)
    }

    func testControlWriteStopsAfterStopReceiving() {
        let central = make()
        _ = makeReady(central)
        central.stopReceiving()
        central.send(.ack(Ack(eventId: UUID(), result: .posted)))
        XCTAssertEqual(driver.controlWrites, [])
    }

    func testOnLinkReadyFiresOncePerReadyTransition() {
        let central = make()
        var fired = 0
        central.onLinkReady = { fired += 1 }
        let p = makeReady(central)
        XCTAssertEqual(fired, 1)
        central.handleLink(.linkReady(p))
        XCTAssertEqual(fired, 1)
    }

    func testEventDataReachesTheHandlerInOrder() throws {
        let central = make()
        var seen: [Data] = []
        central.eventHandler = { seen.append($0) }
        _ = makeReady(central)
        for (id, body) in [(UInt16(1), "a"), (2, "b")] {
            for frame in try FrameCodec.split(Data(body.utf8), messageId: id, maxFrameBytes: 182) {
                central.receive(eventData: frame)
            }
        }
        XCTAssertEqual(seen, [Data("a".utf8), Data("b".utf8)])
    }

    // MARK: T07 framing

    func testEventDataIsIgnoredUnlessTheLinkIsReady() throws {
        let central = make()
        var seen: [Data] = []
        central.eventHandler = { seen.append($0) }
        let frames = try FrameCodec.split(Data("x".utf8), messageId: 1, maxFrameBytes: 182)
        for frame in frames { central.receive(eventData: frame) }
        XCTAssertTrue(seen.isEmpty, "idle")
        central.startReceiving()
        central.handleLink(.power(.poweredOn))
        let p = UUID()
        central.handleLink(.discovered(p))
        central.handleLink(.connected(p))
        for frame in frames { central.receive(eventData: frame) }
        XCTAssertTrue(seen.isEmpty, "a connection that is not ready yet has no notification channel")
        central.handleLink(.linkReady(p))
        for frame in frames { central.receive(eventData: frame) }
        XCTAssertEqual(seen, [Data("x".utf8)])
        central.stopReceiving()
        for frame in frames { central.receive(eventData: frame) }
        XCTAssertEqual(seen.count, 1, "and none after the link is gone")
    }

    func testCentralReassemblesBeforeHandingToPipeline() throws {
        let central = make()
        var seen: [Data] = []
        central.eventHandler = { seen.append($0) }
        _ = makeReady(central)
        let payload = Data((0..<400).map { UInt8(truncatingIfNeeded: $0) })
        let frames = try FrameCodec.split(payload, messageId: 3, maxFrameBytes: 182)
        XCTAssertEqual(frames.count, 3)
        central.receive(eventData: frames[0])
        central.receive(eventData: frames[1])
        XCTAssertTrue(seen.isEmpty, "a partial message never reaches the handler")
        central.receive(eventData: frames[2])
        XCTAssertEqual(seen, [payload], "three frames, one handler call")
    }

    func testLeavingReadyResetsReassemblerWithoutANewReady() throws {
        let central = make()
        var seen: [Data] = []
        central.eventHandler = { seen.append($0) }
        let p = makeReady(central)
        let frames = try FrameCodec.split(Data(repeating: 7, count: 300), messageId: 6, maxFrameBytes: 182)
        XCTAssertEqual(frames.count, 2)
        central.receive(eventData: frames[0])
        central.handleLink(.disconnected(p))
        // No new ready follows, so only the reset on leaving ready can have dropped the partial message.
        if case .ready = central.linkState { return XCTFail("link should have left ready") }
        central.receive(eventData: frames[1])
        XCTAssertTrue(seen.isEmpty, "the second frame must not complete the old message")
    }

    func testNewMessageAfterAnUnfinishedOneStillReachesTheHandler() throws {
        let central = make()
        var seen: [Data] = []
        central.eventHandler = { seen.append($0) }
        _ = makeReady(central)
        let first = try FrameCodec.split(Data(repeating: 1, count: 400), messageId: 1, maxFrameBytes: 182)
        central.receive(eventData: first[0])
        for frame in try FrameCodec.split(Data([2]), messageId: 2, maxFrameBytes: 182) { central.receive(eventData: frame) }
        XCTAssertEqual(seen, [Data([2])])
    }

    func testBytesThatAreNotAFrameNeverReachTheHandler() {
        let central = make()
        var seen: [Data] = []
        central.eventHandler = { seen.append($0) }
        _ = makeReady(central)
        central.receive(eventData: Data("{\"protocolVersion\":1}".utf8))
        central.receive(eventData: Data())
        XCTAssertTrue(seen.isEmpty)
    }

    func testLinkLostResetsReassembler() throws {
        let central = make()
        var seen: [Data] = []
        central.eventHandler = { seen.append($0) }
        let p = makeReady(central)
        let frames = try FrameCodec.split(Data(repeating: 7, count: 400), messageId: 4, maxFrameBytes: 182)
        central.receive(eventData: frames[0])
        central.handleLink(.disconnected(p))
        central.handleLink(.rescanTimer)
        central.handleLink(.discovered(p))
        central.handleLink(.connected(p))
        central.handleLink(.linkReady(p))
        // The rest of the old message arrives on the new connection: it must not be completed from stale state.
        central.receive(eventData: frames[1])
        central.receive(eventData: frames[2])
        XCTAssertTrue(seen.isEmpty)
        for frame in try FrameCodec.split(Data([1]), messageId: 5, maxFrameBytes: 182) { central.receive(eventData: frame) }
        XCTAssertEqual(seen, [Data([1])])
    }

    func testEditableFocusArmsAnIdleReceiver() {
        let central = make()
        XCTAssertFalse(central.isArmed)
        central.focusGainedEditable()
        XCTAssertTrue(central.isArmed)
        XCTAssertEqual(madeDrivers, 1)
    }

    // MARK: T06 reconnect hardening

    func testReadyTimeStartsWhenThePeripheralIsAcceptedNotWhenItIsMerelySeen() {
        var now: Int64 = 1_000
        let central = make(monotonicMs: { now })
        let p = UUID()
        central.startReceiving()
        central.handleLink(.power(.poweredOn))
        // The first sighting is accepted; further sightings while connecting are ignored and must not move the clock.
        central.handleLink(.discovered(p))
        now = 1_300
        central.handleLink(.discovered(UUID()))
        central.handleLink(.discovered(p))
        now = 1_500
        central.handleLink(.connected(p))
        now = 1_900
        central.handleLink(.linkReady(p))
        XCTAssertEqual(central.readyMilliseconds, 900)
    }

    func testASightingWhileIdleDoesNotStartTheClock() {
        var now: Int64 = 0
        let central = make(monotonicMs: { now })
        let p = UUID()
        central.handleLink(.discovered(UUID()))
        central.startReceiving()
        central.handleLink(.power(.poweredOn))
        now = 5_000
        central.handleLink(.discovered(p))
        now = 5_250
        central.handleLink(.connected(p))
        central.handleLink(.linkReady(p))
        XCTAssertEqual(central.readyMilliseconds, 250)
    }

    func testBluetoothOffNeverSendsStopScanOrCancelButForgetsThePeripheral() {
        let central = make()
        let p = UUID()
        central.startReceiving()
        central.handleLink(.power(.poweredOn))
        central.handleLink(.power(.poweredOff))
        XCTAssertEqual(driver.calls, [.startScan], "no stopScan to a radio that is off")
        central.handleLink(.power(.poweredOn))
        central.handleLink(.discovered(p))
        central.handleLink(.connected(p))
        central.handleLink(.linkReady(p))
        driver.calls.removeAll()
        central.handleLink(.power(.poweredOff))
        XCTAssertEqual(driver.calls, [.forget(p)], "no cancel to a radio that is off, but the peripheral is released")
    }

    func testReadyTimeAfterABluetoothCycleMeasuresOnlyTheNewDiscovery() {
        var now: Int64 = 0
        let central = make(monotonicMs: { now })
        let p = UUID()
        central.startReceiving()
        central.handleLink(.power(.poweredOn))
        now = 1_000
        central.handleLink(.discovered(p))
        now = 1_400
        central.handleLink(.connected(p))
        central.handleLink(.linkReady(p))
        XCTAssertEqual(central.readyMilliseconds, 400)

        now = 2_000
        central.handleLink(.power(.poweredOff))
        XCTAssertNil(central.readyMilliseconds)
        now = 6_000
        central.handleLink(.power(.poweredOn))
        now = 9_000
        central.handleLink(.discovered(p))
        now = 9_300
        central.handleLink(.connected(p))
        now = 9_450
        central.handleLink(.linkReady(p))
        XCTAssertEqual(central.readyMilliseconds, 450, "measured from this discovery, not from the one before the cycle")
    }

    func testStopWhilePoweredOnStillCancels() {
        let central = make()
        let p = UUID()
        central.startReceiving()
        central.handleLink(.power(.poweredOn))
        central.handleLink(.discovered(p))
        central.handleLink(.connected(p))
        central.handleLink(.linkReady(p))
        central.stopReceiving()
        XCTAssertEqual(driver.calls.last, .cancel(p))
    }

    func testRepeatedHandshakeFailuresWaitForTheBackoffBeforeScanning() {
        let central = make()
        let p = UUID()
        central.startReceiving()
        central.handleLink(.power(.poweredOn))
        for _ in 0..<2 {
            central.handleLink(.discovered(p))
            central.handleLink(.connectTimeout)
        }
        XCTAssertEqual(driver.calls.filter { $0 == .startScan }.count, 2, "initial scan plus the immediate first retry")
        driver.calls.removeAll()
        central.handleLink(.discovered(p))
        XCTAssertEqual(driver.calls, [], "a sighting during the backoff is not connected to")
        central.handleLink(.rescanTimer)
        XCTAssertEqual(driver.calls, [.startScan])
    }

    func testStopCancelsAPendingBackoff() {
        let central = make()
        let p = UUID()
        central.startReceiving()
        central.handleLink(.power(.poweredOn))
        for _ in 0..<2 {
            central.handleLink(.discovered(p))
            central.handleLink(.connectTimeout)
        }
        driver.calls.removeAll()
        central.stopReceiving()
        central.handleLink(.rescanTimer)
        XCTAssertEqual(driver.calls, [], "nothing scans after stop, not even when the old timer fires")
        XCTAssertEqual(central.linkState, .idle)
    }

    func testOnLinkLostFiresWhenLeavingReadyOnly() {
        let central = make()
        var lost = 0
        central.onLinkLost = { lost += 1 }
        let p = UUID()
        central.startReceiving()
        central.handleLink(.power(.poweredOn))
        central.handleLink(.discovered(p))
        central.handleLink(.connectTimeout)
        XCTAssertEqual(lost, 0, "a failed handshake never had a link")
        central.handleLink(.discovered(p)); central.handleLink(.connected(p)); central.handleLink(.linkReady(p))
        central.handleLink(.disconnected(p))
        XCTAssertEqual(lost, 1)
        central.handleLink(.discovered(p)); central.handleLink(.connected(p)); central.handleLink(.linkReady(p))
        central.stopReceiving()
        XCTAssertEqual(lost, 2)
        central.startReceiving()
        central.handleLink(.discovered(p)); central.handleLink(.connected(p)); central.handleLink(.linkReady(p))
        central.handleLink(.power(.poweredOff))
        XCTAssertEqual(lost, 3)
    }
}
