import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

@MainActor
private final class FakeDriver: CentralDriving {
    enum Call: Equatable { case startScan, stopScan, connect(UUID), discover(UUID), cancel(UUID) }
    var calls: [Call] = []
    var controlWrites: [Data] = []
    func writeControl(_ data: Data) { controlWrites.append(data) }
    func startScan() { calls.append(.startScan) }
    func stopScan() { calls.append(.stopScan) }
    func connect(_ id: UUID) { calls.append(.connect(id)) }
    func discover(_ id: UUID) { calls.append(.discover(id)) }
    func cancel(_ id: UUID) { calls.append(.cancel(id)) }
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

    private func make(clock: @escaping () -> Date = Date.init) -> ReceiverBLECentral {
        ReceiverBLECentral(defaults: defaults, clock: clock) { [unowned self] _ in
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

    func testEventDataReachesTheHandlerInOrder() {
        let central = make()
        var seen: [Data] = []
        central.eventHandler = { seen.append($0) }
        central.receive(eventData: Data("a".utf8))
        central.receive(eventData: Data("b".utf8))
        XCTAssertEqual(seen, [Data("a".utf8), Data("b".utf8)])
    }

    func testEditableFocusArmsAnIdleReceiver() {
        let central = make()
        XCTAssertFalse(central.isArmed)
        central.focusGainedEditable()
        XCTAssertTrue(central.isArmed)
        XCTAssertEqual(madeDrivers, 1)
    }
}
