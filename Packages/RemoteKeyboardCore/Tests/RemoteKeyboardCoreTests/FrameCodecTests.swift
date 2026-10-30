import XCTest
@testable import RemoteKeyboardCore

final class FrameCodecTests: XCTestCase {
    func testSplitFitsEachFrameWithinMax() throws {
        let payload = Data(repeating: 0x41, count: 1_000)
        let frames = try FrameCodec.split(payload, messageId: 7, maxFrameBytes: 182)
        XCTAssertTrue(frames.allSatisfy { $0.count <= 182 })
        XCTAssertEqual(frames.count, Int((1_000.0 / 177.0).rounded(.up)))
    }

    func testHeaderLayoutIsVersionMessageIdBigEndianIndexCount() throws {
        let frames = try FrameCodec.split(Data(repeating: 0x42, count: 400), messageId: 0x0102, maxFrameBytes: 182)
        XCTAssertEqual(frames.count, 3)
        for (i, frame) in frames.enumerated() {
            XCTAssertEqual(Array(frame.prefix(5)), [0x02, 0x01, 0x02, UInt8(i), 3])
        }
    }

    func testSplitThenReassembleRoundTrips() throws {
        for size in [0, 1, 177, 178, 16_384] {
            let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
            let frames = try FrameCodec.split(payload, messageId: 9, maxFrameBytes: 182)
            var reassembler = FrameReassembler()
            var results: [ReassemblyResult] = []
            for frame in frames { results.append(reassembler.accept(frame)) }
            XCTAssertEqual(results.last, .complete(payload), "size \(size)")
            XCTAssertTrue(results.dropLast().allSatisfy { $0 == .incomplete }, "size \(size)")
        }
    }

    func testEmptyPayloadIsOneHeaderOnlyFrame() throws {
        let frames = try FrameCodec.split(Data(), messageId: 1, maxFrameBytes: 182)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].count, FrameCodec.headerBytes)
    }

    func testFrameSmallerThanHeaderPlusOneThrows() {
        XCTAssertThrowsError(try FrameCodec.split(Data([1]), messageId: 1, maxFrameBytes: 5)) {
            XCTAssertEqual($0 as? FrameError, .frameTooSmall)
        }
        XCTAssertThrowsError(try FrameCodec.split(Data([1]), messageId: 1, maxFrameBytes: 0)) {
            XCTAssertEqual($0 as? FrameError, .frameTooSmall)
        }
    }

    func testPayloadOverMaxThrows() {
        let payload = Data(repeating: 0, count: 16_385)
        XCTAssertThrowsError(try FrameCodec.split(payload, messageId: 1, maxFrameBytes: 182)) {
            XCTAssertEqual($0 as? FrameError, .payloadTooLarge(16_385))
        }
    }

    func testMoreThan255FramesThrowsInsteadOfWrapping() {
        // 6 bytes per frame leaves one payload byte, so 300 bytes would need 300 frames.
        XCTAssertThrowsError(try FrameCodec.split(Data(repeating: 0, count: 300), messageId: 1, maxFrameBytes: 6)) {
            XCTAssertEqual($0 as? FrameError, .payloadTooLarge(300))
        }
        XCTAssertNoThrow(try FrameCodec.split(Data(repeating: 0, count: 255), messageId: 1, maxFrameBytes: 6))
    }

    func testVersion1PayloadRejectedAsUnsupported() throws {
        let v1 = Data("""
        {"eventId":"\(UUID().uuidString)","focusEpoch":7,"kind":{"text":{"_0":"A"}},"protocolVersion":1,"seq":1,"sessionId":"\(UUID().uuidString)"}
        """.utf8)
        XCTAssertThrowsError(try PeripheralCodec.decode(v1)) {
            XCTAssertEqual($0 as? EventCodecError, .unsupportedVersion(1))
        }
    }

    func testPeripheralMessageRoundTripsEveryKind() throws {
        let kinds: [EventKind] = [.text("香港"), .backspace, .returnKey, .ping(shownAtMs: 10, connectedAtMs: 20)]
        for kind in kinds {
            let e = KeyboardEvent(
                protocolVersion: KeyboardEvent.currentVersion, eventId: UUID(), sessionId: UUID(), seq: 3, focusEpoch: nil, kind: kind)
            XCTAssertEqual(try PeripheralCodec.decode(PeripheralCodec.encode(.event(e))), .event(e))
        }
    }

    func testCurrentVersionIsThree() { XCTAssertEqual(KeyboardEvent.currentVersion, 3) }

    func testPeripheralCodecRejectsUnknownTypeAndGarbage() throws {
        XCTAssertThrowsError(try PeripheralCodec.decode(Data("{".utf8))) { XCTAssertEqual($0 as? EventCodecError, .malformed) }
        let unknown = Data("{\"protocolVersion\":3,\"type\":\"nope\"}".utf8)
        XCTAssertThrowsError(try PeripheralCodec.decode(unknown)) { XCTAssertEqual($0 as? EventCodecError, .malformed) }
        let future = Data("{\"protocolVersion\":4,\"type\":\"event\"}".utf8)
        XCTAssertThrowsError(try PeripheralCodec.decode(future)) { XCTAssertEqual($0 as? EventCodecError, .unsupportedVersion(4)) }
    }

    func testEncodeOverMaxMessageThrowsTooLarge() {
        let e = KeyboardEvent(
            protocolVersion: KeyboardEvent.currentVersion, eventId: UUID(), sessionId: UUID(), seq: 1, focusEpoch: 1,
            kind: .text(String(repeating: "A", count: 17_000)))
        XCTAssertThrowsError(try PeripheralCodec.encode(.event(e))) {
            guard case .tooLarge(let size)? = $0 as? EventCodecError else { return XCTFail("\($0)") }
            XCTAssertGreaterThan(size, FrameCodec.maxMessageBytes)
        }
    }

    func testUTF8AndEmojiSurviveSplitAcrossFrames() throws {
        let text = String(repeating: "香港👨‍👩‍👧‍👦café", count: 200)
        let e = KeyboardEvent(
            protocolVersion: KeyboardEvent.currentVersion, eventId: UUID(), sessionId: UUID(), seq: 1, focusEpoch: 4, kind: .text(text))
        let data = try PeripheralCodec.encode(.event(e))
        let frames = try FrameCodec.split(data, messageId: 12, maxFrameBytes: 182)
        XCTAssertGreaterThan(frames.count, 1)
        var reassembler = FrameReassembler()
        var complete: Data?
        for frame in frames { if case .complete(let d) = reassembler.accept(frame) { complete = d } }
        let message = try PeripheralCodec.decode(try XCTUnwrap(complete))
        guard case .event(let decoded) = message, case .text(let back) = decoded.kind else { return XCTFail() }
        XCTAssertEqual(back, text)
    }

    func testDebugSizedTextOf3000CharactersFitsOneMessage() throws {
        let text = String(repeating: "一二三四五六七八九十ABCDEFGHIJ", count: 150)
        XCTAssertEqual(text.count, 3_000)
        let e = KeyboardEvent(
            protocolVersion: KeyboardEvent.currentVersion, eventId: UUID(), sessionId: UUID(), seq: 1, focusEpoch: 4, kind: .text(text))
        let frames = try FrameCodec.split(try PeripheralCodec.encode(.event(e)), messageId: 1, maxFrameBytes: 182)
        XCTAssertLessThanOrEqual(frames.count, FrameCodec.maxFrameCount)
        var reassembler = FrameReassembler()
        var results: [ReassemblyResult] = []
        for frame in frames { results.append(reassembler.accept(frame)) }
        guard case .complete(let data)? = results.last, case .event(let back) = try PeripheralCodec.decode(data) else {
            return XCTFail("not complete")
        }
        XCTAssertEqual(back, e)
        print("3000-char TEXT: \(frames.count) frames at 182 bytes")
    }
}
