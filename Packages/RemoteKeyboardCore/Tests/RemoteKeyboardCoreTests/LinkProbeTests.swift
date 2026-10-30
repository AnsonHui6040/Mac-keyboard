import XCTest
@testable import RemoteKeyboardCore

final class LinkProbeTests: XCTestCase {
    private let id = UUID()

    func testNothingPendingNeverExpires() {
        let probe = LinkProbe()
        XCTAssertFalse(probe.isPending)
        XCTAssertFalse(probe.isExpired(nowMs: 1_000_000))
    }

    func testProbeExpiresAfterTwoSecondsWithoutPong() {
        var probe = LinkProbe()
        XCTAssertTrue(probe.start(eventId: id, nowMs: 10_000))
        XCTAssertTrue(probe.isPending)
        XCTAssertEqual(LinkProbe.timeoutMs, 2000)
        XCTAssertFalse(probe.isExpired(nowMs: 10_000))
        XCTAssertFalse(probe.isExpired(nowMs: 11_999))
        XCTAssertTrue(probe.isExpired(nowMs: 12_000))
        XCTAssertTrue(probe.isExpired(nowMs: 15_000))
    }

    func testPongForProbeCancelsDeadline() {
        var probe = LinkProbe()
        _ = probe.start(eventId: id, nowMs: 10_000)
        XCTAssertTrue(probe.pongReceived(eventId: id))
        XCTAssertFalse(probe.isPending)
        XCTAssertFalse(probe.isExpired(nowMs: 99_000))
        XCTAssertFalse(probe.pongReceived(eventId: id), "a second pong for the same probe is not news")
    }

    func testPongForOtherEventDoesNotCancel() {
        var probe = LinkProbe()
        _ = probe.start(eventId: id, nowMs: 10_000)
        XCTAssertFalse(probe.pongReceived(eventId: UUID()))
        XCTAssertTrue(probe.isPending)
        XCTAssertTrue(probe.isExpired(nowMs: 12_000))
    }

    func testSecondStartWhilePendingKeepsTheFirstDeadline() {
        var probe = LinkProbe()
        XCTAssertTrue(probe.start(eventId: id, nowMs: 10_000))
        XCTAssertFalse(probe.start(eventId: UUID(), nowMs: 11_500))
        XCTAssertTrue(probe.isExpired(nowMs: 12_000), "the first probe's clock keeps running")
        XCTAssertTrue(probe.pongReceived(eventId: id))
    }

    func testCancelAndRestart() {
        var probe = LinkProbe()
        _ = probe.start(eventId: id, nowMs: 10_000)
        probe.cancel()
        XCTAssertFalse(probe.isPending)
        XCTAssertFalse(probe.isExpired(nowMs: 20_000))
        let next = UUID()
        XCTAssertTrue(probe.start(eventId: next, nowMs: 20_000))
        XCTAssertFalse(probe.pongReceived(eventId: id))
        XCTAssertTrue(probe.pongReceived(eventId: next))
    }
}
