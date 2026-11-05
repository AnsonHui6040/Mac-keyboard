import ApplicationServices
import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

/// Hands out scripted focus reads; the last one repeats. `delay` simulates a hung target app.
final class ScriptedFocusReader: FocusReading, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [FocusReadResult]
    private let delays: [TimeInterval]
    private var reads = 0

    /// `delays[n]` is the sleep of the n-th call; the last value repeats.
    init(_ results: [FocusReadResult], delay: TimeInterval = 0, delays: [TimeInterval]? = nil) {
        self.results = results
        self.delays = delays ?? [delay]
    }

    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }

    func read(pid: pid_t) -> FocusReadResult {
        lock.lock()
        let index = reads
        reads += 1
        let result = results.count > 1 ? results.removeFirst() : results[0]
        let delay = delays[min(index, delays.count - 1)]
        lock.unlock()
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return result
    }
}

enum FocusFixtures {
    static let elementA = FocusReadResult(element: AXUIElementCreateSystemWide(), editable: true)
    static let elementB = FocusReadResult(element: AXUIElementCreateApplication(1), editable: true)

    @MainActor
    static func environment(trusted: Bool = true) -> FocusEnvironment {
        FocusEnvironment(trusted: { trusted }, frontmost: { (42, "TextEdit") }, ownPID: 1)
    }

    /// An environment whose frontmost app the test can change.
    @MainActor
    final class Frontmost {
        var pid: Int32 = 42
        var name = "TextEdit"
        var environment: FocusEnvironment {
            FocusEnvironment(trusted: { true }, frontmost: { [self] in (pid, name) }, ownPID: 1)
        }
    }
}

@MainActor
final class FocusMonitorTests: XCTestCase {
    func testPollIntervalIsFastOnlyWhileALinkIsActive() {
        XCTAssertEqual(FocusMonitor.pollInterval(linkActive: true), 0.25)
        XCTAssertEqual(FocusMonitor.pollInterval(linkActive: false), 2.0)
    }

    func testSetLinkActiveReschedulesOnlyWhenTheIntervalChanges() {
        let monitor = FocusMonitor(reader: ScriptedFocusReader([FocusFixtures.elementA]), environment: FocusFixtures.environment())
        monitor.start()
        defer { monitor.stop() }
        XCTAssertEqual(monitor.scheduledPollInterval, 2.0)
        let idleTimer = monitor.scheduledTimerForTesting
        monitor.setLinkActive(false)
        XCTAssertTrue(monitor.scheduledTimerForTesting === idleTimer, "unchanged: same timer")
        monitor.setLinkActive(true)
        XCTAssertEqual(monitor.scheduledPollInterval, 0.25)
        let fastTimer = monitor.scheduledTimerForTesting
        monitor.setLinkActive(true)
        XCTAssertTrue(monitor.scheduledTimerForTesting === fastTimer, "unchanged: same timer")
        monitor.setLinkActive(false)
        XCTAssertEqual(monitor.scheduledPollInterval, 2.0)
    }

    func testBecomingActiveReadsAtOnce() async {
        let reader = ScriptedFocusReader([FocusFixtures.elementA])
        let monitor = FocusMonitor(reader: reader, environment: FocusFixtures.environment())
        monitor.start()
        defer { monitor.stop() }
        for _ in 0..<100 where reader.readCount < 1 { try? await Task.sleep(for: .milliseconds(10)) }
        let before = reader.readCount
        monitor.setLinkActive(true)
        for _ in 0..<100 where reader.readCount <= before { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(reader.readCount, before, "the first status after connecting is fresh")
    }

    func testSetLinkActiveBeforeStartOnlyRemembersTheState() {
        let reader = ScriptedFocusReader([FocusFixtures.elementA])
        let monitor = FocusMonitor(reader: reader, environment: FocusFixtures.environment())
        monitor.setLinkActive(true)
        XCTAssertTrue(monitor.isLinkActive)
        XCTAssertNil(monitor.scheduledPollInterval)
        XCTAssertEqual(reader.readCount, 0)
    }

    func testSlowAXReadDoesNotBlockMainThread() async {
        let reader = ScriptedFocusReader([FocusFixtures.elementA], delay: 2)
        let monitor = FocusMonitor(reader: reader, environment: FocusFixtures.environment())

        var longestGap: TimeInterval = 0
        var ticks = 0
        let ticker = Task { @MainActor in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                let now = ContinuousClock.now
                let gap = now - last
                longestGap = max(longestGap, Double(gap.components.seconds) + Double(gap.components.attoseconds) / 1e18)
                last = now
                ticks += 1
            }
        }
        let started = ContinuousClock.now
        let snapshot = await monitor.refreshNow()
        let elapsed = ContinuousClock.now - started
        ticker.cancel()

        XCTAssertGreaterThanOrEqual(elapsed, .seconds(2), "the read really took 2 s")
        XCTAssertTrue(snapshot.editable)
        XCTAssertGreaterThan(ticks, 20, "the main actor kept ticking while AX was busy")
        XCTAssertLessThan(longestGap, 0.5, "no main-thread stall")
    }

    func testEpochAdvancesOnlyWhenTheElementChanges() async {
        let reader = ScriptedFocusReader([FocusFixtures.elementA, FocusFixtures.elementA, FocusFixtures.elementB])
        let monitor = FocusMonitor(reader: reader, environment: FocusFixtures.environment())
        let first = await monitor.refreshNow()
        let second = await monitor.refreshNow()
        let third = await monitor.refreshNow()
        XCTAssertEqual(first.epoch, second.epoch)
        XCTAssertEqual(third.epoch, second.epoch + 1)
    }

    func testUntrustedOrOwnProcessNeverReachesTheReader() async {
        let reader = ScriptedFocusReader([FocusFixtures.elementA])
        let monitor = FocusMonitor(reader: reader, environment: FocusFixtures.environment(trusted: false))
        let snapshot = await monitor.refreshNow()
        XCTAssertFalse(snapshot.axTrusted)
        XCTAssertFalse(snapshot.editable)
        XCTAssertEqual(reader.readCount, 0)
    }

    func testFrontmostAppChangingDuringTheReadFailsClosed() async {
        let front = FocusFixtures.Frontmost()
        let reader = ScriptedFocusReader([FocusFixtures.elementA], delay: 0.6)
        let monitor = FocusMonitor(reader: reader, environment: front.environment)
        let before = await monitor.refreshNow()
        XCTAssertTrue(before.editable)

        let task = Task { await monitor.refreshNow() }
        try? await Task.sleep(for: .milliseconds(200))
        front.pid = 99
        front.name = "Safari"
        let after = await task.value
        XCTAssertFalse(after.editable, "the element belongs to the app that was frontmost before the switch")
        XCTAssertEqual(after.frontmostPID, 99)
        XCTAssertGreaterThan(after.epoch, before.epoch)
    }

    func testOlderReadFinishingLaterDoesNotOverwriteNewer() async {
        // First call is slow and sees A; second call is fast and sees B.
        let reader = ScriptedFocusReader([FocusFixtures.elementA, FocusFixtures.elementB], delays: [0.8, 0])
        let monitor = FocusMonitor(reader: reader, environment: FocusFixtures.environment())
        let slow = Task { await monitor.refreshNow() }
        try? await Task.sleep(for: .milliseconds(150))
        let fast = await monitor.refreshNow()
        let slowResult = await slow.value
        XCTAssertEqual(monitor.snapshot, fast, "the newer read stays applied")
        XCTAssertEqual(slowResult, fast, "the older call hands back the newer snapshot")
        XCTAssertEqual(fast.epoch, 1, "one change from nothing to B; A was never applied")
    }

    func testRestoreNoticeShowsAndClearsOnlyOnceNotABC() {
        var current = InputSourceSwitcher.asciiID
        let notice = InputSourceNotice(currentID: { current })
        XCTAssertNil(notice.message)
        notice.report(restoredOK: false)
        XCTAssertEqual(notice.message, "輸入法未能切回，請手動切換")
        notice.report(restoredOK: true)
        XCTAssertEqual(notice.message, "輸入法未能切回，請手動切換", "still on ABC, so the warning stays")
        notice.sourceChanged()
        XCTAssertNotNil(notice.message)
        current = "com.apple.inputmethod.TCIM.Zhuyin"
        notice.sourceChanged()
        XCTAssertNil(notice.message, "the user switched back by hand")
    }
}
