import XCTest
@testable import RemoteKeyboardCore

final class TrackpadSendRateTests: XCTestCase {
    func test_defaultAndRange() {
        XCTAssertEqual(TrackpadSendRate.defaultValue, TrackpadSendRate.automatic)
        XCTAssertEqual(TrackpadSendRate.automatic, 0)
        XCTAssertTrue(TrackpadSendRate.isAutomatic(0))
        XCTAssertFalse(TrackpadSendRate.isAutomatic(120))
        XCTAssertEqual(TrackpadSendRate.minimum, 20)
        XCTAssertEqual(TrackpadSendRate.maximum, 120)
        XCTAssertEqual(TrackpadSendRate.step, 10)
    }

    func test_clampsAndSnapsToTheGrid() {
        XCTAssertEqual(TrackpadSendRate.clamped(0), 0, "0 is 自動")
        XCTAssertEqual(TrackpadSendRate.clamped(-5), 20)
        XCTAssertEqual(TrackpadSendRate.clamped(500), 120)
        XCTAssertEqual(TrackpadSendRate.clamped(64), 60)
        XCTAssertEqual(TrackpadSendRate.clamped(66), 70)
        XCTAssertEqual(TrackpadSendRate.clamped(Int.max), 120)
        XCTAssertEqual(TrackpadSendRate.clamped(Int.min), 20)
    }

    func test_garbageGivesTheDefault() {
        XCTAssertEqual(TrackpadSendRate.clamped(nil as Any?), 0, "nothing stored under the new key is 自動")
        XCTAssertEqual(TrackpadSendRate.clamped("fast" as Any?), 0)
        XCTAssertEqual(TrackpadSendRate.clamped(Double.nan as Any?), 0)
        XCTAssertEqual(TrackpadSendRate.clamped(Double.infinity as Any?), 0)
        XCTAssertEqual(TrackpadSendRate.clamped(true as Any?), 0)
        XCTAssertEqual(TrackpadSendRate.clamped(0 as Any?), 0)
        XCTAssertEqual(TrackpadSendRate.clamped(-3 as Any?), 20)
        XCTAssertEqual(TrackpadSendRate.clamped(80 as Any?), 80)
        XCTAssertEqual(TrackpadSendRate.clamped(80.0 as Any?), 80)
        XCTAssertEqual(TrackpadSendRate.clamped(1000 as Any?), 120)
    }

    func test_steppingStaysOnTheGridAndStopsAtTheEnds() {
        XCTAssertEqual(TrackpadSendRate.stepped(60, by: 1), 70)
        XCTAssertEqual(TrackpadSendRate.stepped(60, by: -1), 50)
        XCTAssertEqual(TrackpadSendRate.stepped(20, by: -1), 20)
        var walk = 20
        for _ in 0..<30 { walk = TrackpadSendRate.stepped(walk, by: 1) }
        XCTAssertEqual(walk, TrackpadSendRate.automatic, "120 and + is 自動")
        XCTAssertEqual(TrackpadSendRate.stepped(120, by: 1), TrackpadSendRate.automatic)
        XCTAssertEqual(TrackpadSendRate.stepped(TrackpadSendRate.automatic, by: 1), TrackpadSendRate.automatic)
        XCTAssertEqual(TrackpadSendRate.stepped(TrackpadSendRate.automatic, by: -1), 120)
        XCTAssertEqual(TrackpadSendRate.stepped(TrackpadSendRate.automatic, by: -2), 110)
        XCTAssertEqual(TrackpadSendRate.all, [20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120])
    }

    func test_displayText() {
        XCTAssertEqual(TrackpadSendRate.displayText(60), "60 次/秒")
        XCTAssertEqual(TrackpadSendRate.displayText(500), "120 次/秒")
        XCTAssertEqual(TrackpadSendRate.displayText(0), "自動")
    }

    func test_intervalFromRate() {
        XCTAssertEqual(Double(TrackpadSendRate.intervalMicros(60)), 16_667, accuracy: 1)
        XCTAssertEqual(Double(TrackpadSendRate.intervalMicros(120)), 8_333, accuracy: 1)
        XCTAssertEqual(TrackpadSendRate.intervalMicros(20), 50_000)
        XCTAssertEqual(TrackpadSendRate.intervalMicros(7), TrackpadSendRate.intervalMicros(10), "garbage is snapped first")
    }

    func test_displayLinkAsksFor120AboveSixtyAndSixtyAtOrBelow() {
        for rate in TrackpadSendRate.all {
            let range = TrackpadSendRate.frameRate(for: rate)
            if rate > 60 {
                XCTAssertEqual(range.preferred, 120, "rate \(rate)")
                XCTAssertEqual(range.minimum, 80, "rate \(rate)")
                XCTAssertEqual(range.maximum, 120, "rate \(rate)")
            } else {
                XCTAssertEqual(range.preferred, 60, "rate \(rate)")
                XCTAssertEqual(range.minimum, 60, "rate \(rate)")
                XCTAssertEqual(range.maximum, 120, "rate \(rate)")
            }
            XCTAssertGreaterThanOrEqual(range.preferred, Float(rate))
        }
        XCTAssertEqual(TrackpadSendRate.frameRate(for: 60).preferred, 60)
        XCTAssertEqual(TrackpadSendRate.frameRate(for: 90).preferred, 120)
        XCTAssertEqual(TrackpadSendRate.frameRate(for: TrackpadSendRate.automatic).preferred, 120, "自動 runs the display link at 120")
        XCTAssertEqual(TrackpadSendRate.frameRate(for: TrackpadSendRate.automatic).minimum, 80)
    }

    func test_appGroupKeyIsStable() {
        XCTAssertEqual(AppGroup.Key.trackpadSendRate, "rk.trackpadSendRate.v2")
        XCTAssertEqual(AppGroup.Key.trackpadSensitivity, "rk.trackpadSensitivity")
    }

    /// Runs `ticks` display ticks of `tickMicros` with a finger moving every tick and returns when each open MOVE left.
    private func sendTimes(rate: Int, tickMicros: UInt64, ticks: Int) -> [UInt64] {
        let sender = PointerSender()
        sender.rate = rate
        sender.strokeBegan(atMicros: 0)
        var sentAt: [UInt64] = []
        var now: UInt64 = 0
        for _ in 0..<ticks {
            now += tickMicros
            sender.addMove(dx: 1, dy: 0, atMicros: now)
            while let p = sender.peek(nowMicros: now) {
                sender.handedOff(nowMicros: now)
                if p.opcode == .move { sentAt.append(now) }
            }
        }
        return sentAt
    }

    func test_tokenBucketAveragesTheSetRateOnA120HzTick() {
        let tick: UInt64 = 8_333
        let ticks = Int(1_000_000 / tick)
        for rate in [20, 60, 90, 100, 120] {
            let sent = sendTimes(rate: rate, tickMicros: tick, ticks: ticks).count
            XCTAssertEqual(Double(sent), Double(rate), accuracy: 1, "rate \(rate)")
        }
    }

    func test_ninetyOnA120HzTickSendsThreeOfEveryFourTicks() {
        let times = sendTimes(rate: 90, tickMicros: 8_333, ticks: 40)
        XCTAssertEqual(Double(times.count), 30, accuracy: 1)
        let gaps = zip(times, times.dropFirst()).map { ($1 - $0) / 8_333 }
        XCTAssertTrue(gaps.allSatisfy { $0 == 1 || $0 == 2 }, "\(gaps)")
    }

    func test_creditDoesNotBuildUpDuringRest() {
        let sender = PointerSender()
        sender.rate = 60
        sender.strokeBegan(atMicros: 0)
        sender.addMove(dx: 1, dy: 0, atMicros: 1_000)
        XCTAssertNotNil(sender.peek(nowMicros: 1_000))
        sender.handedOff(nowMicros: 1_000)
        // A long pause, then a lot of movement: one packet now, the next only after a full interval.
        var now: UInt64 = 10_000_000
        sender.addMove(dx: 3, dy: 0, atMicros: now)
        XCTAssertNotNil(sender.peek(nowMicros: now))
        sender.handedOff(nowMicros: now)
        now += 1_000
        sender.addMove(dx: 3, dy: 0, atMicros: now)
        XCTAssertNil(sender.peek(nowMicros: now), "no burst from the time spent resting")
        now += 16_000
        XCTAssertNotNil(sender.peek(nowMicros: now))
    }

    func test_afterARestThereIsNoCatchUpBurstInTheFirstTwoIntervals() {
        let sender = PointerSender()
        sender.rate = 90
        sender.strokeBegan(atMicros: 0)
        sender.addMove(dx: 1, dy: 0, atMicros: 1_000)
        _ = sender.peek(nowMicros: 1_000)
        sender.handedOff(nowMicros: 1_000)
        // Ticks go on during a rest of more than a second, with nothing to send.
        var now: UInt64 = 1_000
        while now < 1_500_000 {
            now += 8_333
            XCTAssertNil(sender.peek(nowMicros: now))
        }
        sender.strokeBegan(atMicros: now)
        let begin = now
        var sentAt: [UInt64] = []
        for _ in 0..<120 {
            now += 8_333
            sender.addMove(dx: 1, dy: 0, atMicros: now)
            while let p = sender.peek(nowMicros: now) {
                sender.handedOff(nowMicros: now)
                if p.opcode == .move { sentAt.append(now) }
            }
        }
        let window = begin + 2 * 1_000_000 / 90
        XCTAssertLessThanOrEqual(sentAt.filter { $0 <= window }.count, 1, "only the first one; no catch-up burst")
        XCTAssertEqual(Double(sentAt.count), 90, accuracy: 1)
    }

    func test_automaticModeSendsAsSoonAsThereIsMovement() {
        let sender = PointerSender()
        sender.rate = TrackpadSendRate.automatic
        sender.strokeBegan(atMicros: 0)
        var sent = 0
        for tick in 1...100 {
            let now = UInt64(tick) * 1_000
            sender.addMove(dx: 1, dy: 0, atMicros: now)
            while sender.peek(nowMicros: now) != nil {
                sender.handedOff(nowMicros: now)
                sent += 1
            }
        }
        XCTAssertEqual(sent, 100, "one packet per look that has movement, whatever the interval")
        XCTAssertNil(sender.peek(nowMicros: 200_000), "nothing is formed without movement")
    }

    func test_automaticModeCarriesEverythingAcrossARefusalIntoOnePacket() throws {
        let sender = PointerSender()
        sender.rate = TrackpadSendRate.automatic
        sender.strokeBegan(atMicros: 0)
        sender.addMove(dx: 1, dy: 0, atMicros: 1_000)
        XCTAssertNotNil(sender.peek(nowMicros: 1_000))
        sender.refused()
        for tick in 2...5 {
            sender.addMove(dx: 1, dy: 0, atMicros: UInt64(tick) * 1_000)
            XCTAssertNil(sender.peek(nowMicros: UInt64(tick) * 1_000), "blocked")
        }
        sender.radioReady()
        let packet = try XCTUnwrap(sender.peek(nowMicros: 6_000))
        XCTAssertEqual(packet.dx, 5 * 16, "all five points in one packet")
        XCTAssertEqual(packet.status & PointerPayload.statusAfterBlock, PointerPayload.statusAfterBlock)
        sender.handedOff(nowMicros: 6_000)
        XCTAssertNil(sender.peek(nowMicros: 6_000))
    }

    func test_automaticModeKeepsTheOrderOfMovementClickAndButton() {
        let sender = PointerSender()
        sender.rate = TrackpadSendRate.automatic
        sender.strokeBegan(atMicros: 0)
        sender.addMove(dx: 2, dy: 0, atMicros: 1_000)
        sender.click(atMicros: 2_000)
        sender.addMove(dx: 3, dy: 0, atMicros: 3_000)
        sender.setLeftButton(true, atMicros: 4_000)
        sender.addMove(dx: 4, dy: 0, atMicros: 5_000)
        var opcodes: [PointerPayload.Opcode] = []
        var dxs: [Int16] = []
        while let p = sender.peek(nowMicros: 5_000) {
            sender.handedOff(nowMicros: 5_000)
            opcodes.append(p.opcode)
            dxs.append(p.dx)
        }
        XCTAssertEqual(opcodes, [.move, .click, .move, .buttonState, .move])
        XCTAssertEqual(dxs, [32, 0, 48, 0, 64])
    }

    func test_theFirstMoveOfAStrokeGoesAtOnce() {
        let sender = PointerSender()
        sender.rate = 20
        sender.strokeBegan(atMicros: 0)
        sender.addMove(dx: 2, dy: 0, atMicros: 500)
        XCTAssertEqual(sender.peek(nowMicros: 500)?.opcode, .move)
    }

    func test_aSenderCreatedInAutomaticModeIsNotLimitedFromTheStart() {
        let sender = PointerSender(rate: TrackpadSendRate.automatic)
        sender.strokeBegan(atMicros: 0)
        var sent = 0
        for tick in 1...10 {
            let now = UInt64(tick) * 1_000
            sender.addMove(dx: 1, dy: 0, atMicros: now)
            while sender.peek(nowMicros: now) != nil {
                sender.handedOff(nowMicros: now)
                sent += 1
            }
        }
        XCTAssertEqual(sent, 10)
    }

    func test_senderDefaultRateIsSixty() {
        XCTAssertEqual(PointerSender().rate, 60)
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
