import XCTest
@testable import RemoteKeyboardCore

final class TrackpadSendRateTests: XCTestCase {
    func test_defaultAndRange() {
        XCTAssertEqual(TrackpadSendRate.defaultValue, 60)
        XCTAssertEqual(TrackpadSendRate.minimum, 20)
        XCTAssertEqual(TrackpadSendRate.maximum, 120)
        XCTAssertEqual(TrackpadSendRate.step, 10)
    }

    func test_clampsAndSnapsToTheGrid() {
        XCTAssertEqual(TrackpadSendRate.clamped(0), 20)
        XCTAssertEqual(TrackpadSendRate.clamped(-5), 20)
        XCTAssertEqual(TrackpadSendRate.clamped(500), 120)
        XCTAssertEqual(TrackpadSendRate.clamped(64), 60)
        XCTAssertEqual(TrackpadSendRate.clamped(66), 70)
        XCTAssertEqual(TrackpadSendRate.clamped(Int.max), 120)
        XCTAssertEqual(TrackpadSendRate.clamped(Int.min), 20)
    }

    func test_garbageGivesTheDefault() {
        XCTAssertEqual(TrackpadSendRate.clamped(nil as Any?), 60)
        XCTAssertEqual(TrackpadSendRate.clamped("fast" as Any?), 60)
        XCTAssertEqual(TrackpadSendRate.clamped(Double.nan as Any?), 60)
        XCTAssertEqual(TrackpadSendRate.clamped(Double.infinity as Any?), 60)
        XCTAssertEqual(TrackpadSendRate.clamped(true as Any?), 60)
        XCTAssertEqual(TrackpadSendRate.clamped(80 as Any?), 80)
        XCTAssertEqual(TrackpadSendRate.clamped(80.0 as Any?), 80)
        XCTAssertEqual(TrackpadSendRate.clamped(1000 as Any?), 120)
    }

    func test_steppingStaysOnTheGridAndStopsAtTheEnds() {
        XCTAssertEqual(TrackpadSendRate.stepped(60, by: 1), 70)
        XCTAssertEqual(TrackpadSendRate.stepped(60, by: -1), 50)
        XCTAssertEqual(TrackpadSendRate.stepped(20, by: -1), 20)
        XCTAssertEqual(TrackpadSendRate.stepped(120, by: 1), 120)
        var walk = 20
        for _ in 0..<30 { walk = TrackpadSendRate.stepped(walk, by: 1) }
        XCTAssertEqual(walk, 120)
        XCTAssertEqual(TrackpadSendRate.all, [20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120])
    }

    func test_displayText() {
        XCTAssertEqual(TrackpadSendRate.displayText(60), "60 次/秒")
        XCTAssertEqual(TrackpadSendRate.displayText(500), "120 次/秒")
    }

    func test_intervalFromRate() {
        XCTAssertEqual(Double(TrackpadSendRate.intervalMicros(60)), 16_667, accuracy: 1)
        XCTAssertEqual(Double(TrackpadSendRate.intervalMicros(120)), 8_333, accuracy: 1)
        XCTAssertEqual(TrackpadSendRate.intervalMicros(20), 50_000)
        XCTAssertEqual(TrackpadSendRate.intervalMicros(7), TrackpadSendRate.intervalMicros(10), "garbage is snapped first")
    }

    func test_pacingLeavesRoomForTickJitter() {
        XCTAssertEqual(TrackpadSendRate.pacingMicros(60), 15_000)
        XCTAssertEqual(TrackpadSendRate.pacingMicros(120), 7_500)
        for rate in TrackpadSendRate.all {
            XCTAssertLessThan(TrackpadSendRate.pacingMicros(rate), TrackpadSendRate.intervalMicros(rate))
        }
    }

    func test_displayLinkRangeIsAtLeastTheRate() {
        for rate in TrackpadSendRate.all {
            let range = TrackpadSendRate.frameRate(for: rate)
            XCTAssertGreaterThanOrEqual(range.minimum, Float(min(rate, 60)))
            XCTAssertEqual(range.maximum, 120)
            XCTAssertGreaterThanOrEqual(range.preferred, Float(rate))
        }
    }

    func test_appGroupKeyIsStable() {
        XCTAssertEqual(AppGroup.Key.trackpadSendRate, "rk.trackpadSendRate")
        XCTAssertEqual(AppGroup.Key.trackpadSensitivity, "rk.trackpadSensitivity")
    }

    func test_senderNeverSendsMoreThanOneMovePerPacingInterval() {
        for rate in [20, 60, 120] {
            let sender = PointerSender()
            sender.pacingMicros = TrackpadSendRate.pacingMicros(rate)
            sender.strokeBegan(atMicros: 0)
            var sentAt: [UInt64] = []
            var now: UInt64 = 0
            // Touches arrive every 1 ms for one second; the "display" asks every 1 ms too, far faster than any rate.
            for _ in 0..<1_000 {
                now += 1_000
                sender.addMove(dx: 1, dy: 0, atMicros: now)
                while let p = sender.peek(nowMicros: now) {
                    sender.handedOff(nowMicros: now)
                    if p.opcode == .move { sentAt.append(now) }
                }
            }
            for (a, b) in zip(sentAt, sentAt.dropFirst()) {
                XCTAssertGreaterThanOrEqual(b - a, TrackpadSendRate.pacingMicros(rate), "rate \(rate)")
            }
            XCTAssertLessThanOrEqual(sentAt.count, Int(1_000_000 / TrackpadSendRate.pacingMicros(rate)) + 1, "rate \(rate)")
            XCTAssertGreaterThanOrEqual(sentAt.count, rate - 5, "rate \(rate) still reaches about its rate")
        }
    }

    func test_senderDefaultPacingIsUnchanged() {
        XCTAssertEqual(PointerSender().pacingMicros, PointerSender.moveIntervalMicros)
    }
}

final class TrackpadSensitivityStorageTests: XCTestCase {
    func test_appGroupValueWins() {
        let r = TrackpadSensitivity.resolved(appGroup: 1.5 as Any?, legacy: 2.0 as Any?)
        XCTAssertEqual(r.value, 1.5)
        XCTAssertFalse(r.migrated)
    }

    func test_legacyIsUsedOnceWhenGroupIsEmpty() {
        let r = TrackpadSensitivity.resolved(appGroup: nil, legacy: 2.2 as Any?)
        XCTAssertEqual(r.value, 2.2)
        XCTAssertTrue(r.migrated)
    }

    func test_nothingStoredGivesDefault() {
        let r = TrackpadSensitivity.resolved(appGroup: nil, legacy: nil)
        XCTAssertEqual(r.value, 1.0)
        XCTAssertFalse(r.migrated)
    }

    func test_garbageAndOutOfRange() {
        XCTAssertEqual(TrackpadSensitivity.resolved(appGroup: "x" as Any?, legacy: nil).value, 1.0)
        XCTAssertEqual(TrackpadSensitivity.resolved(appGroup: 9.0 as Any?, legacy: nil).value, 3.0)
        XCTAssertEqual(TrackpadSensitivity.resolved(appGroup: Double.nan as Any?, legacy: nil).value, 1.0)
        // A garbage group value does not block a good legacy one.
        let r = TrackpadSensitivity.resolved(appGroup: "x" as Any?, legacy: 0.5 as Any?)
        XCTAssertEqual(r.value, 0.5)
        XCTAssertTrue(r.migrated)
    }
}
