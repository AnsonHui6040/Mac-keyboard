import XCTest
@testable import RemoteKeyboardCore

final class LinkLatencyPolicyTests: XCTestCase {
    func testIdleAfterTenSeconds() {
        XCTAssertEqual(LinkLatencyPolicy.idleAfterMs, 10_000)
    }

    func testNoActivityYetIsHigh() {
        let policy = LinkLatencyPolicy()
        XCTAssertEqual(policy.desired(atMs: 0), .high)
        XCTAssertNil(policy.nextChangeAtMs(atMs: 0))
    }

    func testActivityGivesMediumUntilTheBoundary() {
        var policy = LinkLatencyPolicy()
        policy.noteActivity(atMs: 5_000)
        XCTAssertEqual(policy.desired(atMs: 5_000), .medium)
        XCTAssertEqual(policy.desired(atMs: 14_999), .medium)
        XCTAssertEqual(policy.desired(atMs: 15_000), .high)
        XCTAssertEqual(policy.desired(atMs: 99_000), .high)
    }

    func testNextChangeIsTheIdleDeadlineOnlyWhileMedium() {
        var policy = LinkLatencyPolicy()
        policy.noteActivity(atMs: 5_000)
        XCTAssertEqual(policy.nextChangeAtMs(atMs: 6_000), 15_000)
        XCTAssertNil(policy.nextChangeAtMs(atMs: 15_000), "already high: nothing left to wait for")
    }

    func testLaterActivityMovesTheDeadline() {
        var policy = LinkLatencyPolicy()
        policy.noteActivity(atMs: 0)
        policy.noteActivity(atMs: 9_000)
        XCTAssertEqual(policy.desired(atMs: 10_000), .medium)
        XCTAssertEqual(policy.nextChangeAtMs(atMs: 10_000), 19_000)
    }

    func testOpenPointerOverridesIdleAndHasNoDeadline() {
        var policy = LinkLatencyPolicy()
        policy.setPointerOpen(true)
        XCTAssertEqual(policy.desired(atMs: 0), .low)
        XCTAssertEqual(policy.desired(atMs: 1_000_000), .low)
        XCTAssertNil(policy.nextChangeAtMs(atMs: 1_000_000))
        policy.noteActivity(atMs: 1_000)
        XCTAssertEqual(policy.desired(atMs: 2_000), .low)
        XCTAssertNil(policy.nextChangeAtMs(atMs: 2_000))
    }

    func testClosingThePointerReturnsToMediumByLastActivity() {
        var policy = LinkLatencyPolicy()
        policy.noteActivity(atMs: 1_000)
        policy.setPointerOpen(true)
        policy.setPointerOpen(false)
        XCTAssertEqual(policy.desired(atMs: 5_000), .medium)
        XCTAssertEqual(policy.nextChangeAtMs(atMs: 5_000), 11_000)
        XCTAssertEqual(policy.desired(atMs: 11_000), .high)
    }

    func testClosingAfterALongPointerSessionIsHighWhenNothingRecent() {
        var policy = LinkLatencyPolicy()
        policy.noteActivity(atMs: 0)
        policy.setPointerOpen(true)
        policy.setPointerOpen(false)
        XCTAssertEqual(policy.desired(atMs: 60_000), .high)
    }
}
