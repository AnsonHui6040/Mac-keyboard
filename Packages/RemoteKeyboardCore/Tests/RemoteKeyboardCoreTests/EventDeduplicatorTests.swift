import XCTest
@testable import RemoteKeyboardCore

final class EventDeduplicatorTests: XCTestCase {
    private let session = UUID()

    private func event(seq: UInt64, session: UUID? = nil, id: UUID = UUID()) -> KeyboardEvent {
        KeyboardEvent(
            protocolVersion: KeyboardEvent.currentVersion, eventId: id, sessionId: session ?? self.session,
            seq: seq, focusEpoch: 1, kind: .backspace)
    }

    func testDuplicateEventIdReturnsCachedAckWithoutInjecting() {
        var d = EventDeduplicator(); let e = event(seq: 1)
        XCTAssertEqual(d.check(e), .fresh); d.record(e, result: .posted)
        XCTAssertEqual(d.check(e), .duplicate(.posted))
    }

    func testDuplicateReturnsTheOriginalResultNotAlwaysPosted() {
        var d = EventDeduplicator(); let e = event(seq: 1)
        d.record(e, result: .injectFailed)
        XCTAssertEqual(d.check(e), .duplicate(.injectFailed))
    }

    func testCheckAloneDoesNotRememberTheEvent() {
        let d = EventDeduplicator(); let e = event(seq: 1)
        XCTAssertEqual(d.check(e), .fresh)
        XCTAssertEqual(d.check(e), .fresh, "only record() makes an event known")
    }

    func testLowerSeqSameSessionIsOutOfOrder() {
        var d = EventDeduplicator()
        let two = event(seq: 2); d.record(two, result: .posted)
        XCTAssertEqual(d.check(event(seq: 1)), .outOfOrder)
        XCTAssertEqual(d.check(event(seq: 2)), .outOfOrder, "an equal seq with a new eventId is not newer")
    }

    func testHigherSeqSameSessionIsFreshEvenWithAGap() {
        var d = EventDeduplicator()
        d.record(event(seq: 1), result: .posted)
        XCTAssertEqual(d.check(event(seq: 5)), .fresh, "keys lost to a link drop leave gaps, which are fine")
    }

    func testDuplicateWinsOverOutOfOrder() {
        var d = EventDeduplicator()
        let one = event(seq: 1), two = event(seq: 2)
        d.record(one, result: .posted); d.record(two, result: .staleFocus)
        XCTAssertEqual(d.check(one), .duplicate(.posted))
    }

    func testNewSessionStartsFresh() {
        var d = EventDeduplicator()
        d.record(event(seq: 9), result: .posted)
        XCTAssertEqual(d.check(event(seq: 1, session: UUID())), .fresh)
    }

    func testRecordingANewSessionRestartsTheSeqCount() {
        var d = EventDeduplicator(); let other = UUID()
        d.record(event(seq: 9), result: .posted)
        d.record(event(seq: 1, session: other), result: .posted)
        XCTAssertEqual(d.check(event(seq: 2, session: other)), .fresh)
        XCTAssertEqual(d.check(event(seq: 1, session: other)), .outOfOrder)
    }

    func testRecordNeverLowersTheHighestSeq() {
        var d = EventDeduplicator()
        d.record(event(seq: 5), result: .posted)
        d.record(event(seq: 3), result: .posted)
        XCTAssertEqual(d.check(event(seq: 4)), .outOfOrder)
    }

    func testCapacityEvictsOldest() {
        var d = EventDeduplicator(capacity: 2)
        let one = event(seq: 1), two = event(seq: 2), three = event(seq: 3)
        d.record(one, result: .posted); d.record(two, result: .posted); d.record(three, result: .posted)
        XCTAssertEqual(d.check(one), .outOfOrder, "evicted, so no longer a duplicate; its seq is below the maximum")
        XCTAssertEqual(d.check(two), .duplicate(.posted))
        XCTAssertEqual(d.check(three), .duplicate(.posted))
    }

    func testDefaultCapacityKeepsTheLast256() {
        var d = EventDeduplicator()
        let events = (1...300).map { event(seq: UInt64($0)) }
        for e in events { d.record(e, result: .posted) }
        XCTAssertEqual(d.check(events[299]), .duplicate(.posted))
        XCTAssertEqual(d.check(events[43]), .outOfOrder, "the 257th from the end has fallen out")
        XCTAssertEqual(d.check(events[44]), .duplicate(.posted), "the 256th from the end is still kept")
    }
}
