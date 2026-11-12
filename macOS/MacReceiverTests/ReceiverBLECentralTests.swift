import CoreBluetooth
import ObjectiveC
import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

@MainActor
private final class FakeDriver: CentralDriving {
    enum Call: Equatable { case startScan, stopScan, connect(UUID), discover(UUID), cancel(UUID), forget(UUID) }
    var calls: [Call] = []
    var controlWrites: [Data] = []
    func writeControl(_ data: Data) -> Bool { controlWrites.append(data); return true }
    var scans: [[UUID]] = []
    func startScan(services: [UUID]) {
        scans.append(services)
        calls.append(.startScan)
    }
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
        ReceiverBLECentral(
            hostId: TestIdentity.hostId, defaults: defaults, clock: clock, monotonicMs: monotonicMs,
            makeDriver: { [unowned self] _ in
                madeDrivers += 1
                return driver
            })
    }

    func testStaysIdleAndCreatesNoDriverUntilArmed() {
        let central = make()
        XCTAssertEqual(central.linkState, .idle)
        XCTAssertEqual(madeDrivers, 0)
        XCTAssertEqual(central.linkLabel, "尚未開始接收")
        XCTAssertNil(central.remainingSeconds)
    }

    func testManualStartArmsAndScansOncePowered() {
        let central = make()
        central.startReceiving()
        XCTAssertTrue(central.isArmed)
        XCTAssertEqual(madeDrivers, 1)
        central.handleLink(.power(.poweredOn))
        XCTAssertEqual(driver.calls, [.startScan])
        XCTAssertEqual(central.linkLabel, "未連線，正在尋找 iPhone")
    }

    func testReadyLabelIsPlainWithoutMilliseconds() {
        let central = make()
        let p = UUID()
        central.startReceiving()
        central.handleLink(.power(.poweredOn))
        central.handleLink(.discovered(p))
        central.handleLink(.connected(p))
        central.handleLink(.linkReady(p))
        XCTAssertEqual(driver.calls, [.startScan, .stopScan, .connect(p), .discover(p)])
        XCTAssertEqual(central.linkLabel, "已連線")
    }

    func testEveryLinkStateHasPlainWording() {
        let central = make()
        let p = UUID()
        central.startReceiving()
        central.handleLink(.power(.poweredOff))
        XCTAssertEqual(central.linkLabel, "無法接收")
        central.handleLink(.power(.poweredOn))
        XCTAssertEqual(central.linkLabel, "未連線，正在尋找 iPhone")
        central.handleLink(.discovered(p))
        XCTAssertEqual(central.linkLabel, "正在連線 iPhone")
        central.handleLink(.connected(p))
        XCTAssertEqual(central.linkLabel, "正在連線 iPhone")
        central.handleLink(.linkReady(p))
        XCTAssertEqual(central.linkLabel, "已連線")
        for label in ["無法接收", "未連線，正在尋找 iPhone", "正在連線 iPhone", "已連線"] {
            XCTAssertFalse(label.contains("Link"))
            XCTAssertFalse(label.contains("ms"))
        }
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

    // MARK: Panel visibility and the tick

    func testArmedWithThePanelClosedHasNoTickTimer() {
        let central = make()
        central.startReceiving()
        XCTAssertTrue(central.isArmed)
        XCTAssertFalse(central.isTicking)
    }

    func testOpeningThePanelWhileArmedUpdatesNowAndTicks() {
        var current = Date(timeIntervalSince1970: 1000)
        let central = make(clock: { current })
        central.startReceiving()
        current = Date(timeIntervalSince1970: 1050)
        central.setPanelVisible(true)
        XCTAssertEqual(central.now, current, "becoming visible refreshes now at once")
        XCTAssertTrue(central.isTicking)
    }

    func testClosingThePanelStopsTheTick() {
        let central = make()
        central.startReceiving()
        central.setPanelVisible(true)
        central.setPanelVisible(false)
        XCTAssertFalse(central.isTicking)
    }

    func testDisarmedNeverTicksAndDisarmingStopsAnOpenPanelsTick() {
        let central = make()
        central.setPanelVisible(true)
        XCTAssertFalse(central.isTicking, "not armed")
        central.startReceiving()
        XCTAssertTrue(central.isTicking)
        central.stopReceiving()
        XCTAssertFalse(central.isTicking)
        central.startReceiving()
        XCTAssertTrue(central.isTicking, "armed again with the panel still open")
    }

    func testIdleExpiryDoesNotDependOnThePanelTick() {
        var current = Date(timeIntervalSince1970: 1000)
        let central = make(clock: { current })
        central.startReceiving()
        XCTAssertFalse(central.isTicking)
        current = Date(timeIntervalSince1970: 2800)
        central.handleSession(.timerFired)
        XCTAssertFalse(central.isArmed, "the idle timer, not the tick, ends the session")
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

    func testSelectedDiscoveryIsIgnoredWhileThePairingWindowIsOpen() {
        let central = make()
        let selected = UUID(), pairing = UUID()
        let selectUUID = SelectUUID.make(hostId: TestIdentity.hostId)
        let pairingUUID = UUID(uuidString: GATTServiceSpec.Link.pairingAdvertUUID)!
        central.startReceiving()
        central.handleLink(.power(.poweredOn))
        central.setPairingScan(true)
        driver.calls.removeAll()
        central.peripheralDiscovered(selected, advertisedServices: [selectUUID])
        XCTAssertEqual(central.linkState, .scanning, "the phone that was just cut off must not take the window")
        XCTAssertEqual(driver.calls, [])
        central.peripheralDiscovered(pairing, advertisedServices: [pairingUUID])
        XCTAssertEqual(central.linkState, .connecting(pairing))
        XCTAssertEqual(central.connectionRoute, .pairing)
        central.handleLink(.disconnected(pairing))
        central.setPairingScan(false)
        central.peripheralDiscovered(selected, advertisedServices: [selectUUID])
        XCTAssertEqual(central.linkState, .connecting(selected), "once the window is closed the selected UUID connects again")
        XCTAssertEqual(central.connectionRoute, .selected)
    }

    func testTogglingPairingScanDuringBackoffDoesNotScanEarly() {
        let central = make()
        let p = UUID()
        central.startReceiving()
        central.handleLink(.power(.poweredOn))
        for _ in 0..<2 {
            central.handleLink(.discovered(p))
            central.handleLink(.connectTimeout)
        }
        driver.calls.removeAll()
        central.setPairingScan(true)
        XCTAssertEqual(driver.calls, [], "the backoff is still running; no scan yet")
        central.handleLink(.rescanTimer)
        XCTAssertEqual(driver.calls, [.startScan])
        XCTAssertEqual(driver.scans.last?.count, 2, "the scan that follows the backoff already has the pairing UUID")
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

    func testLinkReasonExplainsAnUnavailableRadio() {
        let central = make()
        XCTAssertNil(central.linkReason)
        central.startReceiving()
        central.handleLink(.power(.poweredOff))
        XCTAssertEqual(central.linkReason, "藍牙已關閉，請在 Mac 開啟藍牙")
        central.handleLink(.power(.unauthorized))
        XCTAssertEqual(central.linkReason, "未授權藍牙，請到系統設定 › 隱私權與安全性 允許")
        central.handleLink(.power(.poweredOn))
        XCTAssertNil(central.linkReason)
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

// MARK: CoreBluetooth wiring

/// CoreBluetooth objects cannot be built with `init`, so the fakes are allocated without one and override the few
/// properties and calls the driver touches. Nothing here reaches a radio.
private final class FakeCBManager: CBCentralManager {
    var fakeState: CBManagerState = .poweredOn
    var scans = 0, stops = 0
    var scanServices: [[CBUUID]?] = []
    var scanOptions: [[String: Any]?] = []
    var connected: [UUID] = []
    var cancelled: [UUID] = []
    override var state: CBManagerState { fakeState }
    override func scanForPeripherals(withServices serviceUUIDs: [CBUUID]?, options: [String: Any]? = nil) {
        scans += 1
        scanServices.append(serviceUUIDs)
        scanOptions.append(options)
    }
    override func stopScan() { stops += 1 }
    override func connect(_ peripheral: CBPeripheral, options: [String: Any]? = nil) { connected.append(peripheral.identifier) }
    override func cancelPeripheralConnection(_ peripheral: CBPeripheral) { cancelled.append(peripheral.identifier) }
    /// Kept for the whole run: deallocating an object that was never initialised by CoreBluetooth raises a KVO error.
    nonisolated(unsafe) private static var keep: [AnyObject] = []
    static func make() -> FakeCBManager {
        let fake = unsafeDowncast(class_createInstance(FakeCBManager.self, 0)! as AnyObject, to: FakeCBManager.self)
        // No Swift initialiser ran, so every stored property is initialised by hand.
        withUnsafeMutablePointer(to: &fake.fakeState) { $0.initialize(to: .poweredOn) }
        withUnsafeMutablePointer(to: &fake.scans) { $0.initialize(to: 0) }
        withUnsafeMutablePointer(to: &fake.stops) { $0.initialize(to: 0) }
        withUnsafeMutablePointer(to: &fake.scanServices) { $0.initialize(to: []) }
        withUnsafeMutablePointer(to: &fake.scanOptions) { $0.initialize(to: []) }
        withUnsafeMutablePointer(to: &fake.connected) { $0.initialize(to: []) }
        withUnsafeMutablePointer(to: &fake.cancelled) { $0.initialize(to: []) }
        keep.append(fake)
        return fake
    }
}

private final class FakeCBPeripheral: CBPeripheral {
    var fakeID = UUID()
    var fakeState: CBPeripheralState = .connected
    var fakeDelegate: CBPeripheralDelegate?
    override var identifier: UUID { fakeID }
    override var state: CBPeripheralState { fakeState }
    override var delegate: CBPeripheralDelegate? {
        get { fakeDelegate }
        set { fakeDelegate = newValue }
    }
    nonisolated(unsafe) private static var keep: [AnyObject] = []
    static func make() -> FakeCBPeripheral {
        let fake = unsafeDowncast(class_createInstance(FakeCBPeripheral.self, 0)! as AnyObject, to: FakeCBPeripheral.self)
        withUnsafeMutablePointer(to: &fake.fakeID) { $0.initialize(to: UUID()) }
        withUnsafeMutablePointer(to: &fake.fakeState) { $0.initialize(to: .connected) }
        withUnsafeMutablePointer(to: &fake.fakeDelegate) { $0.initialize(to: nil) }
        keep.append(fake)
        return fake
    }
}

@MainActor
final class CoreBluetoothDriverWiringTests: XCTestCase {
    private var defaults: UserDefaults!
    private var driver: FakeDriver!

    override func setUp() async throws {
        let name = "rk.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)
        defaults.removePersistentDomain(forName: name)
        driver = FakeDriver()
    }

    private let selectUUID = SelectUUID.make(hostId: TestIdentity.hostId)
    private let pairingUUID = UUID(uuidString: GATTServiceSpec.Link.pairingAdvertUUID)!
    private var selectAdvert: [String: Any] { [CBAdvertisementDataServiceUUIDsKey: [CBUUID(nsuuid: selectUUID)]] }
    private var pairingAdvert: [String: Any] { [CBAdvertisementDataServiceUUIDsKey: [CBUUID(nsuuid: pairingUUID)]] }

    private struct Rig {
        let central: ReceiverBLECentral
        let cb: CoreBluetoothDriver
        let manager: FakeCBManager
    }

    private func rig() -> Rig {
        let central = ReceiverBLECentral(hostId: TestIdentity.hostId, defaults: defaults, makeDriver: { [unowned self] _ in driver })
        let manager = FakeCBManager.make()
        let cb = CoreBluetoothDriver(owner: central) { _ in manager }
        central.startReceiving()
        cb.centralManagerDidUpdateState(manager)
        return Rig(central: central, cb: cb, manager: manager)
    }

    func testCentralAdapterForwardsDidConnectAndDisconnect() {
        let r = rig()
        let peripheral = FakeCBPeripheral.make()
        XCTAssertEqual(r.central.linkState, .scanning, "the power callback reached the owner")

        r.cb.centralManager(r.manager, didDiscover: peripheral, advertisementData: selectAdvert, rssi: -50)
        XCTAssertEqual(r.central.linkState, .connecting(peripheral.identifier), "didDiscover is forwarded as discovered")

        r.cb.connect(peripheral.identifier)
        XCTAssertEqual(r.manager.connected, [peripheral.identifier], "connect goes to the CoreBluetooth manager")
        XCTAssertTrue(peripheral.fakeDelegate === r.cb, "the driver takes the peripheral delegate")

        r.cb.centralManager(r.manager, didConnect: peripheral)
        XCTAssertEqual(r.central.linkState, .discovering(peripheral.identifier), "didConnect is forwarded as connected")

        peripheral.fakeState = .disconnected
        r.cb.centralManager(r.manager, didDisconnectPeripheral: peripheral, error: nil)
        XCTAssertEqual(r.central.linkState, .scanning, "didDisconnect is forwarded and the search resumes")
    }

    func testDidFailToConnectIsForwardedAsDisconnect() {
        let r = rig()
        let peripheral = FakeCBPeripheral.make()
        r.cb.centralManager(r.manager, didDiscover: peripheral, advertisementData: selectAdvert, rssi: -50)
        r.cb.connect(peripheral.identifier)
        peripheral.fakeState = .disconnected
        r.cb.centralManager(r.manager, didFailToConnect: peripheral, error: nil)
        XCTAssertEqual(r.central.linkState, .scanning)
    }

    func testStaleDisconnectOfAnotherPeripheralIsIgnored() {
        let r = rig()
        let current = FakeCBPeripheral.make()
        let stale = FakeCBPeripheral.make()
        r.cb.centralManager(r.manager, didDiscover: current, advertisementData: selectAdvert, rssi: -50)
        r.cb.connect(current.identifier)
        stale.fakeState = .disconnected
        r.cb.centralManager(r.manager, didDisconnectPeripheral: stale, error: nil)
        XCTAssertEqual(r.central.linkState, .connecting(current.identifier))
    }

    func testScanStopAndCancelReachTheManagerOnlyWhilePoweredOn() {
        let r = rig()
        r.cb.startScan(services: [selectUUID])
        r.cb.stopScan()
        XCTAssertEqual(r.manager.scans, 1)
        XCTAssertEqual(r.manager.stops, 1)
        let peripheral = FakeCBPeripheral.make()
        r.cb.centralManager(r.manager, didDiscover: peripheral, advertisementData: selectAdvert, rssi: -50)
        r.manager.fakeState = .poweredOff
        r.cb.startScan(services: [selectUUID])
        r.cb.stopScan()
        r.cb.cancel(peripheral.identifier)
        XCTAssertEqual(r.manager.scans, 1, "no scan with the radio off")
        XCTAssertEqual(r.manager.stops, 1, "no stopScan with the radio off")
        XCTAssertEqual(r.manager.cancelled, [], "no cancel with the radio off")
    }

    func testCancelOfAKnownPeripheralReachesTheManager() {
        let r = rig()
        let peripheral = FakeCBPeripheral.make()
        r.cb.centralManager(r.manager, didDiscover: peripheral, advertisementData: selectAdvert, rssi: -50)
        r.cb.cancel(peripheral.identifier)
        XCTAssertEqual(r.manager.cancelled, [peripheral.identifier])
    }

    // MARK: Scan conditions (docs/protocol/v4.md §1.4)

    /// A central whose real driver is the CoreBluetooth one, on a fake manager, so what reaches `scanForPeripherals` is seen.
    private func scanRig() -> Rig {
        let manager = FakeCBManager.make()
        var driverBox: CoreBluetoothDriver?
        let central = ReceiverBLECentral(hostId: TestIdentity.hostId, defaults: defaults, makeDriver: { owner in
            let cb = CoreBluetoothDriver(owner: owner) { _ in manager }
            driverBox = cb
            return cb
        })
        central.startReceiving()
        let cb = driverBox!
        cb.centralManagerDidUpdateState(manager)
        return Rig(central: central, cb: cb, manager: manager)
    }

    func testScansSelectUUIDOnly() {
        let r = scanRig()
        XCTAssertEqual(r.manager.scanServices.count, 1)
        XCTAssertEqual(r.manager.scanServices.last ?? nil, [CBUUID(nsuuid: selectUUID)],
                       "only this host's selected UUID; neither the old service UUID nor the pairing UUID")
    }

    func testScansPairingUUIDOnlyWhileWindowOpen() {
        let r = scanRig()
        r.central.setPairingScan(true)
        XCTAssertEqual(r.manager.scanServices.last ?? nil, [CBUUID(nsuuid: selectUUID), CBUUID(nsuuid: pairingUUID)])
        r.central.setPairingScan(false)
        XCTAssertEqual(r.manager.scanServices.last ?? nil, [CBUUID(nsuuid: selectUUID)], "reset the moment the window closes")
        XCTAssertEqual(r.manager.scans, 3)
        XCTAssertGreaterThanOrEqual(r.manager.stops, 2, "each change restarts the scan, it does not stack")
    }

    func testScanAllowsDuplicates() {
        let r = scanRig()
        r.central.setPairingScan(true)
        XCTAssertEqual(r.manager.scanOptions.count, 2)
        for options in r.manager.scanOptions {
            XCTAssertEqual(options?[CBCentralManagerScanOptionAllowDuplicatesKey] as? Bool, true)
        }
    }

    func testTheRouteIsTakenFromThisPacketsAdvertisement() {
        let r = scanRig()
        let first = FakeCBPeripheral.make()
        r.cb.centralManager(r.manager, didDiscover: first, advertisementData: selectAdvert, rssi: -50)
        XCTAssertEqual(r.central.linkState, .connecting(first.identifier))
        XCTAssertEqual(r.central.connectionRoute, .selected)

        // The same peripheral later advertises the pairing UUID while the window is open.
        r.central.setPairingScan(true)
        r.central.handleLink(.disconnected(first.identifier))
        first.fakeState = .disconnected
        let second = FakeCBPeripheral.make()
        r.cb.centralManager(r.manager, didDiscover: second, advertisementData: pairingAdvert, rssi: -50)
        XCTAssertEqual(r.central.linkState, .connecting(second.identifier))
        XCTAssertEqual(r.central.connectionRoute, .pairing)
    }

    func testAPairingAdvertIsIgnoredWhenNoWindowIsOpen() {
        let r = scanRig()
        let peripheral = FakeCBPeripheral.make()
        r.cb.centralManager(r.manager, didDiscover: peripheral, advertisementData: pairingAdvert, rssi: -50)
        XCTAssertEqual(r.central.linkState, .scanning, "a packet that arrives after the window closed is not connected to")
    }

    func testAPacketWithoutAKnownUUIDIsIgnored() {
        let r = scanRig()
        let peripheral = FakeCBPeripheral.make()
        let stranger = [CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: GATTServiceSpec.Link.serviceUUID)]]
        r.cb.centralManager(r.manager, didDiscover: peripheral, advertisementData: stranger, rssi: -50)
        XCTAssertEqual(r.central.linkState, .scanning, "the old GATT service UUID is not a reason to connect")
        r.cb.centralManager(r.manager, didDiscover: peripheral, advertisementData: [:], rssi: -50)
        XCTAssertEqual(r.central.linkState, .scanning, "and neither is a packet that names nothing: only this packet counts")
    }

    func testAUUIDInTheOverflowAreaCounts() {
        let r = scanRig()
        let peripheral = FakeCBPeripheral.make()
        let overflow = [CBAdvertisementDataOverflowServiceUUIDsKey: [CBUUID(nsuuid: selectUUID)]]
        r.cb.centralManager(r.manager, didDiscover: peripheral, advertisementData: overflow, rssi: -50)
        XCTAssertEqual(r.central.linkState, .connecting(peripheral.identifier))
    }

    func testRepeatedReportsOfTheSamePeripheralAreHarmless() {
        let r = scanRig()
        let peripheral = FakeCBPeripheral.make()
        for _ in 0..<5 { r.cb.centralManager(r.manager, didDiscover: peripheral, advertisementData: selectAdvert, rssi: -50) }
        XCTAssertEqual(r.central.linkState, .connecting(peripheral.identifier))
        XCTAssertEqual(r.manager.scans, 1, "the repeats start no new scan")
    }
}
