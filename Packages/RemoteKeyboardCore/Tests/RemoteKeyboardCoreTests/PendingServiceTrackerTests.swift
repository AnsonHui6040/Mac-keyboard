import XCTest
@testable import RemoteKeyboardCore

final class PendingServiceTrackerTests: XCTestCase {
    func testMatchingCompletionIsAcceptedOnceAndClears() {
        var t = PendingServiceTracker<Int>()
        t.begin(2)
        XCTAssertTrue(t.accept(2))
        XCTAssertNil(t.pending)
        XCTAssertFalse(t.accept(2), "a duplicate completion is not accepted twice")
    }

    func testStaleCompletionFromAnEarlierAppearanceIsIgnored() {
        var t = PendingServiceTracker<Int>()
        t.begin(1)
        t.begin(2)
        XCTAssertFalse(t.accept(1))
        XCTAssertEqual(t.pending, 2, "the stale one must not consume the real pending add")
        XCTAssertTrue(t.accept(2))
    }

    func testNothingIsAcceptedAfterClear() {
        var t = PendingServiceTracker<Int>()
        t.begin(1)
        t.clear()
        XCTAssertFalse(t.accept(1))
    }

    func testNothingIsAcceptedWhenNothingIsPending() {
        var t = PendingServiceTracker<Int>()
        XCTAssertFalse(t.accept(1))
    }
}
