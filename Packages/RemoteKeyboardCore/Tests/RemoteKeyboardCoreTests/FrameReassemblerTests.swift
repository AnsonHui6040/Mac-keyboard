import XCTest
@testable import RemoteKeyboardCore

final class FrameReassemblerTests: XCTestCase {
    /// Builds a frame by hand so tests can break each header field on its own.
    private func frame(id: UInt16, index: UInt8, count: UInt8, payload: [UInt8] = [1, 2, 3], version: UInt8 = 0x02) -> Data {
        Data([version, UInt8(id >> 8), UInt8(id & 0xFF), index, count] + payload)
    }

    func testDuplicateIndexRejected() throws {
        let frames = try FrameCodec.split(Data(repeating: 0x41, count: 400), messageId: 5, maxFrameBytes: 182)
        XCTAssertEqual(frames.count, 3)
        var r = FrameReassembler()
        XCTAssertEqual(r.accept(frames[0]), .incomplete)
        XCTAssertEqual(r.accept(frames[0]), .rejected(.duplicateIndex))
        XCTAssertEqual(r.accept(frames[1]), .incomplete)
        XCTAssertEqual(r.accept(frames[2]), .complete(Data(repeating: 0x41, count: 400)))
    }

    func testIndexBeyondCountRejected() {
        var r = FrameReassembler()
        XCTAssertEqual(r.accept(frame(id: 1, index: 3, count: 3)), .rejected(.badIndex))
    }

    func testBadHeaderCases() {
        var r = FrameReassembler()
        XCTAssertEqual(r.accept(Data()), .rejected(.frameTooSmall))
        XCTAssertEqual(r.accept(Data([2, 0, 1, 0])), .rejected(.frameTooSmall))
        XCTAssertEqual(r.accept(frame(id: 1, index: 0, count: 1, version: 1)), .rejected(.badHeader))
        XCTAssertEqual(r.accept(frame(id: 1, index: 0, count: 0)), .rejected(.badHeader))
    }

    func testNonZeroFirstFrameWithoutMessageRejected() {
        var r = FrameReassembler()
        XCTAssertEqual(r.accept(frame(id: 1, index: 1, count: 2)), .rejected(.badHeader))
    }

    func testNewMessageDropsPartialOne() {
        var r = FrameReassembler()
        XCTAssertEqual(r.droppedPartialMessages, 0)
        XCTAssertEqual(r.accept(frame(id: 1, index: 0, count: 3)), .incomplete)
        // The new message's first frame discards the old one and is itself processed, so a 1-frame message completes.
        XCTAssertEqual(r.accept(frame(id: 2, index: 0, count: 1, payload: [9])), .complete(Data([9])))
        XCTAssertEqual(r.droppedPartialMessages, 1)
    }

    func testNewMultiFrameMessageAfterDropCompletes() {
        var r = FrameReassembler()
        XCTAssertEqual(r.accept(frame(id: 1, index: 0, count: 3)), .incomplete)
        XCTAssertEqual(r.accept(frame(id: 2, index: 0, count: 2, payload: [1, 2])), .incomplete)
        XCTAssertEqual(r.droppedPartialMessages, 1)
        XCTAssertEqual(r.accept(frame(id: 2, index: 1, count: 2, payload: [3])), .complete(Data([1, 2, 3])))
        XCTAssertEqual(r.droppedPartialMessages, 1)
    }

    func testCompletedMessageIsNotCountedAsDropped() {
        var r = FrameReassembler()
        XCTAssertEqual(r.accept(frame(id: 1, index: 0, count: 1)), .complete(Data([1, 2, 3])))
        XCTAssertEqual(r.accept(frame(id: 2, index: 0, count: 1)), .complete(Data([1, 2, 3])))
        XCTAssertEqual(r.droppedPartialMessages, 0)
    }

    func testStaleFramesOfDroppedMessageAreBadHeader() {
        var r = FrameReassembler()
        XCTAssertEqual(r.accept(frame(id: 1, index: 0, count: 3)), .incomplete)
        XCTAssertEqual(r.accept(frame(id: 2, index: 1, count: 3)), .rejected(.badHeader))
        // The wrong-id frame did not disturb the message in progress.
        XCTAssertEqual(r.accept(frame(id: 1, index: 1, count: 3)), .incomplete)
    }

    func testCountChangeInsideAMessageRejected() {
        var r = FrameReassembler()
        XCTAssertEqual(r.accept(frame(id: 1, index: 0, count: 3)), .incomplete)
        XCTAssertEqual(r.accept(frame(id: 1, index: 1, count: 4)), .rejected(.countMismatch))
    }

    func testResetDropsPartialMessage() {
        var r = FrameReassembler()
        XCTAssertEqual(r.accept(frame(id: 1, index: 0, count: 2)), .incomplete)
        r.reset()
        XCTAssertEqual(r.accept(frame(id: 1, index: 1, count: 2)), .rejected(.badHeader))
    }

    func testMessageOverLimitRejectedAndDropped() {
        var r = FrameReassembler(maxMessageBytes: 10)
        XCTAssertEqual(r.accept(frame(id: 1, index: 0, count: 3, payload: Array(repeating: 1, count: 6))), .incomplete)
        XCTAssertEqual(r.accept(frame(id: 1, index: 1, count: 3, payload: Array(repeating: 1, count: 6))), .rejected(.messageTooLarge))
        XCTAssertEqual(r.accept(frame(id: 1, index: 2, count: 3)), .rejected(.badHeader))
    }

    func testMessageIdWrapsAroundBetweenMessages() throws {
        var r = FrameReassembler()
        for id in [UInt16.max, 0] {
            let frames = try FrameCodec.split(Data([7, 8]), messageId: id, maxFrameBytes: 182)
            XCTAssertEqual(r.accept(frames[0]), .complete(Data([7, 8])))
        }
    }

    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func testFuzzedFramesNeverCrashOrComplete() {
        var rng = SeededGenerator(state: 20_261_030)
        var r = FrameReassembler()
        var completes = 0
        var rejects = 0
        var incompletes = 0
        let total = 1_000
        for i in 0..<total {
            let length = Int.random(in: 0...200, using: &rng)
            var bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &rng) }
            // Half of the frames carry a valid version byte so they get past the first check.
            if i % 2 == 0, bytes.count >= 5 { bytes[0] = 0x02 }
            // A well-formed single frame is a legitimate message, so the fuzz never produces one.
            if bytes.count >= 5, bytes[0] == 0x02, bytes[3] == 0, bytes[4] == 1 { bytes[4] = 0 }
            switch r.accept(Data(bytes)) {
            case .complete: completes += 1
            case .rejected: rejects += 1
            case .incomplete: incompletes += 1
            }
        }
        print("fuzz frames=\(total) complete=\(completes) rejected=\(rejects) incomplete=\(incompletes)")
        XCTAssertEqual(completes, 0)
        XCTAssertEqual(completes + rejects + incompletes, total)
    }
}
