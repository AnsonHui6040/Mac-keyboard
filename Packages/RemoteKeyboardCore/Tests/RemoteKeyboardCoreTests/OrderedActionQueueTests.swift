import XCTest
@testable import RemoteKeyboardCore

@MainActor
private final class Log {
    var entries: [String] = []
}

@MainActor
final class OrderedActionQueueTests: XCTestCase {
    func testActionsRunInOrderEvenWhenAnEarlierOneSuspends() async {
        let queue = OrderedActionQueue()
        let log = Log()
        queue.enqueue { _ in
            try? await Task.sleep(for: .milliseconds(50))
            log.entries.append("space")
        }
        XCTAssertTrue(queue.isBusy)
        queue.enqueue { _ in log.entries.append("symbols") }
        queue.enqueue { _ in log.entries.append("switch") }
        await queue.drain()
        XCTAssertEqual(log.entries, ["space", "symbols", "switch"])
        XCTAssertFalse(queue.isBusy)
    }

    func testResetSkipsPendingActionsAndMarksRunningOnesStale() async {
        let queue = OrderedActionQueue()
        let log = Log()
        queue.enqueue { run in
            try? await Task.sleep(for: .milliseconds(50))
            if run.isCurrent { log.entries.append("first") }
        }
        queue.enqueue { _ in log.entries.append("second") }
        queue.reset()
        XCTAssertFalse(queue.isBusy)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(log.entries, [])
    }

    func testQueueWorksAgainAfterReset() async {
        let queue = OrderedActionQueue()
        let log = Log()
        queue.enqueue { _ in log.entries.append("old") }
        queue.reset()
        queue.enqueue { _ in log.entries.append("new") }
        await queue.drain()
        XCTAssertEqual(log.entries, ["new"])
    }
}
