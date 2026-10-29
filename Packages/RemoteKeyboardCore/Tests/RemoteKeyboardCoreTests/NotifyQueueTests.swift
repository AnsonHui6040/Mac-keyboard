import XCTest
@testable import RemoteKeyboardCore

final class NotifyQueueTests: XCTestCase {
    func testDrainStopsWhenSendReturnsFalseAndKeepsOrder() {
        var q = NotifyQueue(); ["a","b","c"].forEach { q.enqueue(Data($0.utf8)) }
        var sent: [String] = []; q.drain { d in if sent.count == 1 { return false }; sent.append(String(decoding: d, as: UTF8.self)); return true }
        XCTAssertEqual(sent, ["a"]); XCTAssertEqual(q.pendingCount, 2)
        q.drain { d in sent.append(String(decoding: d, as: UTF8.self)); return true }
        XCTAssertEqual(sent, ["a", "b", "c"]); XCTAssertEqual(q.pendingCount, 0)
    }

    func testRejectedFrameIsRetriedFirst() {
        var q = NotifyQueue(); q.enqueue(Data("a".utf8)); q.enqueue(Data("b".utf8))
        var attempts: [String] = []
        q.drain { attempts.append(String(decoding: $0, as: UTF8.self)); return false }
        q.drain { attempts.append(String(decoding: $0, as: UTF8.self)); return true }
        XCTAssertEqual(attempts, ["a", "a", "b"])
    }

    func testEmptyDrainNeverCallsSend() {
        var q = NotifyQueue()
        q.drain { _ in XCTFail("send must not be called"); return true }
        XCTAssertEqual(q.pendingCount, 0)
    }

    func testRemoveAllDropsPendingFrames() {
        var q = NotifyQueue(); q.enqueue(Data("a".utf8))
        q.removeAll()
        XCTAssertEqual(q.pendingCount, 0)
    }
}
