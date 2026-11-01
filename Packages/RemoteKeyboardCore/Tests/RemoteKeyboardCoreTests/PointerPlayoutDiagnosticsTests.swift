import XCTest
@testable import RemoteKeyboardCore

final class PointerPlayoutDiagnosticsTests: XCTestCase {
    private let ms: UInt64 = 1_000

    /// 120 Hz frames from `start`, each with its delivered flag; a MOVE arrived at every frame's start unless `quietAfter` says so.
    private func feed(
        _ d: inout PointerPlayoutDiagnostics, frames: Int, start: UInt64 = 1_000_000, deliveredEvery: (Int) -> Bool = { _ in true },
        moveEvery: Int? = 1, margin: UInt64 = 4_000
    ) {
        for i in 0..<frames {
            let now = start + UInt64(i) * 8_333
            if let moveEvery, i % moveEvery == 0 { d.recordMove(arrivalMicros: now, dxSixteenths: 16, dySixteenths: 0, dtTenths: 160) }
            d.recordFrame(nowMicros: now, timestampMicros: now, targetMicros: now + margin, delivered: deliveredEvery(i))
        }
    }

    func testTooFewFramesGiveNothing() {
        var d = PointerPlayoutDiagnostics()
        feed(&d, frames: 19)
        XCTAssertNil(d.snapshot(nowMicros: 1_000_000 + 19 * 8_333))
        feed(&d, frames: 1, start: 1_000_000 + 19 * 8_333)
        XCTAssertNotNil(d.snapshot(nowMicros: 1_000_000 + 20 * 8_333))
    }

    func testStalledFramesWhileMovingAreCountedWithTheLongestRun() throws {
        var d = PointerPlayoutDiagnostics()
        // 100 frames; frames 10–12 and 40 deliver nothing.
        feed(&d, frames: 100, deliveredEvery: { ![10, 11, 12, 40].contains($0) })
        let s = try XCTUnwrap(d.snapshot(nowMicros: 1_000_000 + 99 * 8_333))
        XCTAssertEqual(s.stalledFramePercent, 4, accuracy: 1e-9)
        XCTAssertEqual(s.longestStall, 3)
    }

    func testFramesWhileNotMovingAreNotCounted() throws {
        var d = PointerPlayoutDiagnostics()
        d.recordMove(arrivalMicros: 1_000_000, dxSixteenths: 16, dySixteenths: 0, dtTenths: 160)
        // The last MOVE is long ago for these 60 frames: not moving, so an empty frame is not a stall.
        for i in 0..<60 {
            let now = 1_500_000 + UInt64(i) * 8_333
            d.recordFrame(nowMicros: now, timestampMicros: now, targetMicros: now + 4_000, delivered: false)
        }
        let s = try XCTUnwrap(d.snapshot(nowMicros: 1_500_000 + 59 * 8_333))
        XCTAssertEqual(s.stalledFramePercent, 0)
        XCTAssertEqual(s.longestStall, 0)
    }

    func testSqueezesAreCountedInTheWindow() throws {
        var d = PointerPlayoutDiagnostics()
        feed(&d, frames: 50)
        d.recordSqueeze(atMicros: 1_100_000)
        d.recordSqueeze(atMicros: 1_200_000)
        let s = try XCTUnwrap(d.snapshot(nowMicros: 1_000_000 + 49 * 8_333))
        XCTAssertEqual(s.squeezeCount, 2)
    }

    func testCallbackIntervalAndMarginPercentiles() throws {
        var d = PointerPlayoutDiagnostics()
        for i in 0..<100 {
            // Intervals alternate 8 and 9 ms in steps; the margin grows from 1 ms to 10 ms.
            let t = 1_000_000 + UInt64(i) * 8_500
            d.recordFrame(nowMicros: t, timestampMicros: t, targetMicros: t + 1_000 + UInt64(i % 10) * 1_000, delivered: true)
        }
        let s = try XCTUnwrap(d.snapshot(nowMicros: 1_000_000 + 99 * 8_500))
        XCTAssertEqual(s.callbackIntervalP50Millis, 8.5, accuracy: 1e-9)
        XCTAssertEqual(s.callbackIntervalP95Millis, 8.5, accuracy: 1e-9)
        XCTAssertEqual(s.marginP10Millis, 1, accuracy: 1e-9)
        XCTAssertEqual(s.marginP50Millis, 5, accuracy: 1e-9)
    }

    func testGainJumpIsZeroAtConstantSpeedAndKnownForAlternatingSpeeds() throws {
        var steady = PointerPlayoutDiagnostics()
        feed(&steady, frames: 40)
        XCTAssertEqual(try XCTUnwrap(steady.snapshot(nowMicros: 1_000_000 + 39 * 8_333)).gainJumpP50, 0, accuracy: 1e-9)

        var d = PointerPlayoutDiagnostics()
        // 10 ms packets of 3 pt (300 pt/s) and 8 pt (800 pt/s), alternating.
        for i in 0..<60 {
            let now = 1_000_000 + UInt64(i) * 10 * ms
            let points = i % 2 == 0 ? 3 : 8
            d.recordMove(arrivalMicros: now, dxSixteenths: Int16(points * 16), dySixteenths: 0, dtTenths: 100)
            d.recordFrame(nowMicros: now, timestampMicros: now, targetMicros: now + 4_000, delivered: true)
        }
        let expected = abs(log(PointerAcceleration.gain(speed: 800) / PointerAcceleration.gain(speed: 300)))
        let s = try XCTUnwrap(d.snapshot(nowMicros: 1_000_000 + 59 * 10 * ms))
        XCTAssertGreaterThan(expected, 0.2)
        XCTAssertEqual(s.gainJumpP50, expected, accuracy: 1e-9)
        XCTAssertEqual(s.gainJumpP90, expected, accuracy: 1e-9)
    }

    func testGainJumpAcrossAStrokeGapIsNotCounted() throws {
        var d = PointerPlayoutDiagnostics()
        // Pairs of packets of very different speed, but each pair is far from the next; inside a pair the speed is the same.
        for i in 0..<40 {
            let now = 1_000_000 + UInt64(i / 2) * 500 * ms + UInt64(i % 2) * 10 * ms
            let points = (i / 2) % 2 == 0 ? 3 : 8
            d.recordMove(arrivalMicros: now, dxSixteenths: Int16(points * 16), dySixteenths: 0, dtTenths: 100)
            d.recordFrame(nowMicros: now, timestampMicros: now, targetMicros: now + 4_000, delivered: true)
        }
        let s = try XCTUnwrap(d.snapshot(nowMicros: 1_000_000 + 19 * 500 * ms + 10 * ms))
        XCTAssertEqual(s.gainJumpP90, 0, accuracy: 1e-9)
    }

    func testOldDataLeavesTheWindowAndResetEmptiesIt() {
        var d = PointerPlayoutDiagnostics()
        feed(&d, frames: 100)
        XCTAssertNotNil(d.snapshot(nowMicros: 1_000_000 + 99 * 8_333))
        XCTAssertNil(d.snapshot(nowMicros: 1_000_000 + 99 * 8_333 + 6_000_000))
        feed(&d, frames: 100, start: 20_000_000)
        d.reset()
        XCTAssertNil(d.snapshot(nowMicros: 20_000_000 + 99 * 8_333))
    }

    func testLinesAreSeparatePlainTaiwaneseTextOnePerValue() throws {
        var d = PointerPlayoutDiagnostics()
        feed(&d, frames: 100, deliveredEvery: { ![10, 11, 12, 40].contains($0) })
        let s = try XCTUnwrap(d.snapshot(nowMicros: 1_000_000 + 99 * 8_333))
        XCTAssertEqual(s.lines.count, 4)
        XCTAssertEqual(s.lines[0], "播放中斷 4%（最長 3 幀）")
        XCTAssertEqual(s.lines[1], "追趕壓縮 0 次")
        XCTAssertEqual(s.lines[2], "刷新回呼間隔 P50 8 ms，P95 8 ms，餘裕 P10 4 ms")
        XCTAssertEqual(s.lines[3], "加速倍率跳動 P50 0.00，P90 0.00")
    }
}
