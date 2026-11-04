import XCTest
@testable import RemoteKeyboardCore

final class LinkResultRecorderTests: XCTestCase {
    private func recorder(remote: Bool = true) -> LinkResultRecorder {
        var r = LinkResultRecorder()
        r.appeared(atMs: 1_000, remote: remote)
        return r
    }

    func testRawValuesAreStable() {
        XCTAssertEqual(LastLinkResult.connected.rawValue, "connected")
        XCTAssertEqual(LastLinkResult.authFailed.rawValue, "authFailed")
        XCTAssertEqual(LastLinkResult.unreachable.rawValue, "unreachable")
    }

    func testConnectedRecordsConnected() {
        var r = recorder()
        XCTAssertEqual(r.linkAuthenticated(), .connected)
    }

    func testAuthFailedRecordsAuthFailed() {
        var r = recorder()
        XCTAssertEqual(r.authenticationFailed(), .authFailed)
    }

    func testRemoteLongPairedNeverConnectedRecordsUnreachable() {
        var r = recorder()
        XCTAssertEqual(r.disappeared(atMs: 11_000, paired: true), .unreachable)
    }

    func testTenSecondsExactlyCounts() {
        var r = recorder()
        XCTAssertEqual(r.disappeared(atMs: 11_000, paired: true), .unreachable)
        var quick = recorder()
        XCTAssertNil(quick.disappeared(atMs: 10_999, paired: true))
    }

    func testQuickAppearanceRecordsNothing() {
        var r = recorder()
        XCTAssertNil(r.disappeared(atMs: 3_000, paired: true))
    }

    func testLocalOnlyAppearanceRecordsNothing() {
        var r = recorder(remote: false)
        XCTAssertNil(r.disappeared(atMs: 60_000, paired: true))
    }

    func testSwitchingToRemoteDuringAppearanceCounts() {
        var r = recorder(remote: false)
        r.modeChanged(remote: true)
        XCTAssertEqual(r.disappeared(atMs: 12_000, paired: true), .unreachable)
    }

    func testUnpairedRecordsNothing() {
        var r = recorder()
        XCTAssertNil(r.disappeared(atMs: 60_000, paired: false))
    }

    func testConnectedAppearanceDoesNotRecordUnreachable() {
        var r = recorder()
        _ = r.linkAuthenticated()
        XCTAssertNil(r.disappeared(atMs: 60_000, paired: true))
    }

    func testAuthFailedAppearanceDoesNotRecordUnreachable() {
        var r = recorder()
        _ = r.authenticationFailed()
        XCTAssertNil(r.disappeared(atMs: 60_000, paired: true))
    }

    func testConnectingAfterAuthFailedAllowsLaterNothingButConnected() {
        var r = recorder()
        _ = r.authenticationFailed()
        XCTAssertEqual(r.linkAuthenticated(), .connected)
        XCTAssertNil(r.disappeared(atMs: 60_000, paired: true))
    }

    func testDisappearWithoutAppearRecordsNothing() {
        var r = LinkResultRecorder()
        XCTAssertNil(r.disappeared(atMs: 60_000, paired: true))
    }

    func testNextAppearanceStartsFresh() {
        var r = recorder()
        _ = r.linkAuthenticated()
        _ = r.disappeared(atMs: 60_000, paired: true)
        r.appeared(atMs: 100_000, remote: true)
        XCTAssertEqual(r.disappeared(atMs: 110_000, paired: true), .unreachable)
    }

    func testRepeatedAppearKeepsOriginalStart() {
        var r = recorder()
        r.appeared(atMs: 5_000, remote: true)
        XCTAssertEqual(r.disappeared(atMs: 11_000, paired: true), .unreachable)
    }

    func testAProblemExpiresAfterADay() {
        let day = LastLinkResult.problemLifetimeSeconds
        XCTAssertEqual(LastLinkResult.current(raw: "unreachable", recordedAt: 100, now: 100 + day - 1), .unreachable)
        XCTAssertNil(LastLinkResult.current(raw: "unreachable", recordedAt: 100, now: 100 + day))
        XCTAssertNil(LastLinkResult.current(raw: "authFailed", recordedAt: nil, now: 100))
    }

    func testConnectedDoesNotExpireAndGarbageIsNothing() {
        XCTAssertEqual(LastLinkResult.current(raw: "connected", recordedAt: nil, now: 1_000_000), .connected)
        XCTAssertNil(LastLinkResult.current(raw: "nonsense", recordedAt: 1, now: 1))
        XCTAssertNil(LastLinkResult.current(raw: nil, recordedAt: 1, now: 1))
    }
}
