import XCTest
@testable import RemoteKeyboardCore

final class ReconnectStatsTests: XCTestCase {
    func testP95NearestRank() {
        let s = (1...100).map { ReconnectSample(shownAtMs: 0, connectedAtMs: Int64($0)) }
        XCTAssertEqual(ReconnectStats.summarize(s), ReconnectSummary(attempts: 100, successes: 100, p95Ms: 95))
    }

    func testFailuresExcludedFromP95() {
        let s = [ReconnectSample(shownAtMs: 0, connectedAtMs: 100), ReconnectSample(shownAtMs: 0, connectedAtMs: nil)]
        XCTAssertEqual(ReconnectStats.summarize(s), ReconnectSummary(attempts: 2, successes: 1, p95Ms: 100))
    }

    func testNoSuccessHasNilP95() {
        XCTAssertNil(ReconnectStats.summarize([ReconnectSample(shownAtMs: 0, connectedAtMs: nil)]).p95Ms)
    }

    func testEmptyInputHasNoAttemptsAndNilP95() {
        XCTAssertEqual(ReconnectStats.summarize([]), ReconnectSummary(attempts: 0, successes: 0, p95Ms: nil))
    }

    func testLatencyIsConnectedMinusShownAndInputOrderDoesNotMatter() {
        let s = [900, 100, 500].map { ReconnectSample(shownAtMs: 1000, connectedAtMs: 1000 + Int64($0)) }
        XCTAssertEqual(ReconnectStats.summarize(s).p95Ms, 900)
    }

    func testRankRoundsUpForSmallCounts() {
        let s = (1...20).map { ReconnectSample(shownAtMs: 0, connectedAtMs: Int64($0 * 10)) }
        // ceil(0.95 * 20) = 19 -> the 19th smallest.
        XCTAssertEqual(ReconnectStats.summarize(s).p95Ms, 190)
        let one = [ReconnectSample(shownAtMs: 5, connectedAtMs: 12)]
        XCTAssertEqual(ReconnectStats.summarize(one).p95Ms, 7)
    }

    // MARK: CSV

    func testCSVLineHasShownConnectedAndLatency() {
        XCTAssertEqual(ReconnectCSV.line(shownAtMs: 1000, connectedAtMs: 1480), "1000,1480,480")
    }

    func testCSVParsingFeedsTheStatsAndSkipsJunk() {
        let text = "1000,1480,480\nnot,a,row\n\n2000,2100,100\n3000,3000\n"
        let samples = ReconnectCSV.samples(from: text)
        XCTAssertEqual(samples, [
            ReconnectSample(shownAtMs: 1000, connectedAtMs: 1480),
            ReconnectSample(shownAtMs: 2000, connectedAtMs: 2100)
        ])
    }
}

final class ReconnectTrackerTests: XCTestCase {
    func testStartsIdleWithNothingToSend() {
        var t = ReconnectTracker()
        XCTAssertFalse(t.isActive)
        XCTAssertNil(t.latencyMs)
        XCTAssertNil(t.takePing(statusReceived: true, linkConnected: true))
    }

    func testBeginRecordsShownOnlyOncePerAppearance() {
        var t = ReconnectTracker()
        XCTAssertTrue(t.beginIfIdle(atMs: 100))
        XCTAssertFalse(t.beginIfIdle(atMs: 900), "a repeated appear must not move shownAt")
        XCTAssertEqual(t.shownAtMs, 100)
    }

    func testConnectedIsRecordedOnTheTransitionIntoConnectedOnly() {
        var t = ReconnectTracker()
        t.beginIfIdle(atMs: 100)
        t.linkChanged(from: .idle, to: .advertising, atMs: 150)
        XCTAssertNil(t.connectedAtMs)
        t.linkChanged(from: .advertising, to: .connected, atMs: 400)
        XCTAssertEqual(t.connectedAtMs, 400)
        XCTAssertEqual(t.latencyMs, 300)
        // A reconnect inside the same appearance, or a repeated event, never overwrites it.
        t.linkChanged(from: .advertising, to: .connected, atMs: 900)
        t.linkChanged(from: .connected, to: .connected, atMs: 950)
        XCTAssertEqual(t.connectedAtMs, 400)
    }

    func testConnectedBeforeAnAppearanceIsIgnored() {
        var t = ReconnectTracker()
        t.linkChanged(from: .advertising, to: .connected, atMs: 400)
        XCTAssertNil(t.connectedAtMs)
        XCTAssertFalse(t.isActive)
    }

    func testPingNeedsConnectedStatusAndLinkAndIsSentOnce() {
        var t = ReconnectTracker()
        t.beginIfIdle(atMs: 100)
        t.linkChanged(from: .advertising, to: .connected, atMs: 400)
        XCTAssertNil(t.takePing(statusReceived: false, linkConnected: true), "waits for the first ReceiverStatus")
        XCTAssertNil(t.takePing(statusReceived: true, linkConnected: false))
        let ping = t.takePing(statusReceived: true, linkConnected: true)
        XCTAssertEqual(ping?.shownAtMs, 100)
        XCTAssertEqual(ping?.connectedAtMs, 400)
        XCTAssertNil(t.takePing(statusReceived: true, linkConnected: true), "exactly one ping per appearance")
    }

    func testNoPingWithoutAConnectedTransition() {
        var t = ReconnectTracker()
        t.beginIfIdle(atMs: 100)
        XCTAssertNil(t.takePing(statusReceived: true, linkConnected: true))
    }

    func testResetStartsAFreshAppearance() {
        var t = ReconnectTracker()
        t.beginIfIdle(atMs: 100)
        t.linkChanged(from: .advertising, to: .connected, atMs: 400)
        _ = t.takePing(statusReceived: true, linkConnected: true)
        t.reset()
        XCTAssertFalse(t.isActive)
        XCTAssertTrue(t.beginIfIdle(atMs: 1000))
        t.linkChanged(from: .advertising, to: .connected, atMs: 1200)
        XCTAssertEqual(t.takePing(statusReceived: true, linkConnected: true)?.connectedAtMs, 1200)
    }

    func testMonotonicClockNeverGoesBackwards() {
        let a = MonotonicClock.nowMs()
        let b = MonotonicClock.nowMs()
        XCTAssertGreaterThanOrEqual(b, a)
    }
}
