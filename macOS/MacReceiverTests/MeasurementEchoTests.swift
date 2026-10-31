#if DEBUG
import CryptoKit
import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

@MainActor
final class MeasurementEchoTests: XCTestCase {
    @MainActor
    final class CursorSpy: MeasureCursorMoving {
        var moves: [Double] = []
        func move(byPoints dx: Double) { moves.append(dx) }
    }

    @MainActor
    final class FlashSpy: MeasureFlashing {
        var flashes = 0
        var active = false
        func setActive(_ active: Bool) { self.active = active }
        func flash() { flashes += 1 }
    }

    @MainActor
    final class CSVSpy: MeasureCSVSink {
        var lines: [String] = []
        var flushes = 0
        func append(_ line: String) { lines.append(line) }
        func flush() { flushes += 1 }
    }

    /// An echo on spies, with the iPhone's channels of the same handshake to play against it.
    @MainActor
    final class Rig {
        let cursor = CursorSpy()
        let flash = FlashSpy()
        let csv = CSVSpy()
        let phone: ChannelSet
        let mac: ChannelSet
        var writes: [Data] = []
        var refuseWrites = false
        var time: UInt64 = 1_000_000
        var step: UInt64 = 0
        var activity = 0
        var echo: MeasurementEcho!
        private var seq: UInt32 = 0

        init() {
            let pairKey = SymmetricKey(data: Data(repeating: 5, count: 32))
            var macHandshake = MacHandshake(pairKey: pairKey, macNonce: Data(repeating: 1, count: 16))
            var phoneHandshake = PhoneHandshake(pairKey: pairKey, phoneNonce: Data(repeating: 2, count: 16))
            guard case .send(let hello) = macHandshake.begin(), case .send(let reply) = phoneHandshake.receive(hello),
                  case .authenticated(let auth) = macHandshake.receive(reply), phoneHandshake.receive(auth) == .authenticated,
                  let mac = macHandshake.takeChannelSet(), let phone = phoneHandshake.takeChannelSet()
            else { fatalError("handshake") }
            self.mac = mac
            self.phone = phone
            echo = MeasurementEcho(
                write: { [unowned self] data in
                    if refuseWrites { return false }
                    writes.append(data)
                    return true
                },
                clock: { [unowned self] in
                    defer { time += step }
                    return time
                },
                cursor: cursor, flash: flash, csv: csv, noteActivity: { [unowned self] in activity += 1 })
        }

        func attachAndStart() {
            echo.attach(mac)
            echo.setMeasureMode(true)
        }

        func probe(_ kind: MeasurePayload.Kind, dx: Int16 = 0, seq: UInt32? = nil, size: Int = 16, phoneTime: UInt64 = 777) throws -> Data {
            self.seq += 1
            let payload = MeasurePayload(kind: kind, dxSixteenths: dx, seq: seq ?? self.seq, phoneTimeMicros: phoneTime)
            return try phone.sealer(.measureP2M).seal(payload.encode(padTo: size))
        }
    }

    private func counter(of packet: Data) -> UInt64 {
        packet[1..<9].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    func testNoEchoWhenMeasureModeOff() throws {
        let rig = Rig()
        rig.echo.attach(rig.mac)
        rig.echo.handle(try rig.probe(.rtt))
        rig.echo.handle(try rig.probe(.cursor, dx: 32))
        XCTAssertTrue(rig.writes.isEmpty)
        XCTAssertTrue(rig.cursor.moves.isEmpty)
        XCTAssertEqual(rig.flash.flashes, 0)
        XCTAssertEqual(rig.echo.counters.ignoredModeOff, 2)
        XCTAssertTrue(rig.csv.lines.isEmpty)
        XCTAssertEqual(rig.activity, 0)
    }

    func testNoEchoBeforeAuthenticated() throws {
        let rig = Rig()
        rig.echo.setMeasureMode(true)
        rig.echo.handle(try rig.probe(.rtt))
        XCTAssertTrue(rig.writes.isEmpty)
        XCTAssertEqual(rig.echo.counters.ignoredUnauthenticated, 1)
        // And after the connection ended.
        rig.echo.attach(rig.mac)
        rig.echo.detach()
        rig.echo.handle(try rig.probe(.rtt))
        XCTAssertTrue(rig.writes.isEmpty)
        XCTAssertEqual(rig.echo.counters.ignoredUnauthenticated, 2)
    }

    func testEchoIsSealedWithM2PKey() throws {
        let rig = Rig()
        rig.step = 25
        rig.attachAndStart()
        rig.echo.handle(try rig.probe(.rtt, seq: 5, phoneTime: 123_456))
        let reply = try XCTUnwrap(rig.writes.first)
        XCTAssertEqual(reply.count, 41)
        XCTAssertEqual(reply[0], 0x7E)
        let plain = try rig.phone.opener(.measureM2P).open(reply).get()
        let echo = try XCTUnwrap(MeasureEchoPayload.decode(plain))
        XCTAssertEqual(echo.seq, 5)
        XCTAssertEqual(echo.phoneTimeMicros, 123_456)
        XCTAssertGreaterThan(echo.macHoldMicros, 0)
        XCTAssertLessThan(echo.macHoldMicros, 1000)
        // Only the measureM2P key opens it.
        XCTAssertEqual(rig.phone.opener(.measureP2M).open(reply), .failure(.authFailed))
        XCTAssertEqual(rig.phone.opener(.pointer).open(reply), .failure(.badMagic))
        XCTAssertEqual(rig.echo.counters.echoed, 1)
    }

    func testBurstIsCountedWithoutAReply() throws {
        let rig = Rig()
        rig.attachAndStart()
        rig.echo.handle(try rig.probe(.burst, size: 157))
        XCTAssertTrue(rig.writes.isEmpty)
        XCTAssertEqual(rig.echo.counters.received, 1)
        XCTAssertEqual(rig.csv.lines.count, 1)
        XCTAssertTrue(rig.csv.lines[0].hasPrefix("1,burst,182,"))
    }

    func testTamperedProbeIgnoredAndCounted() throws {
        let rig = Rig()
        rig.attachAndStart()
        var packet = try rig.probe(.cursor, dx: 64)
        packet[20] ^= 0x01
        rig.echo.handle(packet)
        XCTAssertEqual(rig.echo.counters.rejected, 1)
        XCTAssertEqual(rig.echo.counters.received, 0)
        XCTAssertTrue(rig.cursor.moves.isEmpty)
        XCTAssertEqual(rig.flash.flashes, 0)
        XCTAssertTrue(rig.writes.isEmpty)
        XCTAssertEqual(rig.activity, 0, "a forged packet is not activity")
        // The next genuine packet still works: the forged one did not move the window.
        rig.echo.handle(try rig.probe(.cursor, dx: 16))
        XCTAssertEqual(rig.cursor.moves, [4])
    }

    func testCursorProbeMovesByDxTimesGain() throws {
        let rig = Rig()
        rig.attachAndStart()
        rig.echo.handle(try rig.probe(.cursor, dx: 32))
        XCTAssertEqual(rig.cursor.moves, [8], "32/16 = 2 pt, times the measurement gain of 4")
        XCTAssertEqual(rig.flash.flashes, 1)
        rig.echo.handle(try rig.probe(.cursor, dx: -16))
        XCTAssertEqual(rig.cursor.moves, [8, -4])
        XCTAssertEqual(rig.flash.flashes, 2)
        XCTAssertTrue(rig.writes.isEmpty, "a cursor probe is not answered")
        XCTAssertEqual(rig.activity, 2)
    }

    func testEchoAtMostOneWriteInFlight() throws {
        let rig = Rig()
        rig.attachAndStart()
        rig.echo.handle(try rig.probe(.rtt))
        rig.echo.handle(try rig.probe(.rtt))
        XCTAssertEqual(rig.writes.count, 1)
        XCTAssertEqual(rig.echo.counters.skippedBusy, 1)
        XCTAssertTrue(rig.csv.lines[1].hasSuffix(",-1"), "a skipped probe has no hold time")
        rig.echo.writeCompleted()
        rig.echo.handle(try rig.probe(.rtt))
        XCTAssertEqual(rig.writes.count, 2)
        XCTAssertEqual(rig.echo.counters.echoed, 2)
    }

    func testRefusedWriteDoesNotBlockTheNextEcho() throws {
        let rig = Rig()
        rig.attachAndStart()
        rig.refuseWrites = true
        rig.echo.handle(try rig.probe(.rtt))
        XCTAssertEqual(rig.echo.counters.writeRefused, 1)
        rig.refuseWrites = false
        rig.echo.handle(try rig.probe(.rtt))
        XCTAssertEqual(rig.writes.count, 1, "no write was in flight, so the next probe is answered")
        // The refused ciphertext was discarded: the next reply carries the next counter.
        XCTAssertEqual(counter(of: rig.writes[0]), 2)
    }

    func testMeasureToggleKeepsSealer() throws {
        let rig = Rig()
        rig.attachAndStart()
        rig.echo.handle(try rig.probe(.rtt))
        rig.echo.writeCompleted()
        rig.echo.setMeasureMode(false)
        rig.echo.setMeasureMode(true)
        rig.echo.handle(try rig.probe(.rtt))
        XCTAssertEqual(rig.writes.map(counter(of:)), [1, 2], "the reply counter goes on after the mode was switched off and on")
        XCTAssertNoThrow(try rig.phone.opener(.measureM2P).open(rig.writes[0]).get())
        XCTAssertNoThrow(try rig.phone.opener(.measureM2P).open(rig.writes[1]).get())
    }

    func testModeChangeIsReportedOnceAndSwitchesTheCornerWindow() {
        let rig = Rig()
        var changes = 0
        rig.echo.onModeChange = { changes += 1 }
        rig.echo.setMeasureMode(true)
        XCTAssertTrue(rig.flash.active)
        rig.echo.setMeasureMode(true)
        rig.echo.setMeasureMode(false)
        XCTAssertFalse(rig.flash.active)
        XCTAssertEqual(changes, 2)
    }

    func testDetachForgetsAWriteInFlight() throws {
        let rig = Rig()
        rig.attachAndStart()
        rig.echo.handle(try rig.probe(.rtt))
        rig.echo.detach()
        XCTAssertGreaterThan(rig.csv.flushes, 0, "rows are written out when the connection ends")
        rig.echo.attach(rig.mac)
        rig.echo.handle(try rig.probe(.rtt))
        XCTAssertEqual(rig.writes.count, 2, "a new connection starts with no write in flight")
    }

    func testWatchdogRecorderDoesNotInject() throws {
        let rig = Rig()
        rig.attachAndStart()
        for (seq, at) in [(UInt32(1), UInt64(0)), (2, 100_000), (3, 200_000), (4, 600_000), (5, 700_000)] {
            rig.time = 1_000_000 + at
            rig.echo.handle(try rig.probe(.heartbeat, seq: seq))
        }
        XCTAssertEqual(rig.echo.counters.wouldRelease, 1, "one gap of 400 ms is over the 350 ms the watchdog allows")
        XCTAssertEqual(rig.echo.counters.maxHeartbeatGapMicros, 400_000)
        XCTAssertTrue(rig.cursor.moves.isEmpty, "the recorder never injects a mouse event")
        XCTAssertEqual(rig.flash.flashes, 0)
        XCTAssertTrue(rig.writes.isEmpty)
    }

    func testANewHeartbeatSeriesIsNotAGap() throws {
        let rig = Rig()
        rig.attachAndStart()
        rig.time = 1_000_000
        rig.echo.handle(try rig.probe(.heartbeat, seq: 1))
        rig.time = 9_000_000
        rig.echo.handle(try rig.probe(.heartbeat, seq: 1))
        XCTAssertEqual(rig.echo.counters.wouldRelease, 0)
    }

    func testHeartbeatSeqGoingBackStartsANewSeries() throws {
        let rig = Rig()
        rig.attachAndStart()
        rig.time = 1_000_000
        rig.echo.handle(try rig.probe(.heartbeat, seq: 5))
        // A run that restarts is not a gap, whatever its first seq is.
        rig.time = 3_000_000
        rig.echo.handle(try rig.probe(.heartbeat, seq: 3))
        XCTAssertEqual(rig.echo.counters.wouldRelease, 0)
        rig.time = 3_500_000
        rig.echo.handle(try rig.probe(.heartbeat, seq: 4))
        XCTAssertEqual(rig.echo.counters.wouldRelease, 1, "inside the new series a 500 ms gap is still counted")
    }

    func testCsvHasNoCoordinates() throws {
        XCTAssertEqual(MeasureCSV.header, "seq,kind,bytes,counterGap,interArrivalMicros,holdMicros")
        let rig = Rig()
        rig.step = 1_000
        rig.attachAndStart()
        rig.echo.handle(try rig.probe(.cursor, dx: 4660, seq: 7))
        rig.echo.handle(try rig.probe(.cursor, dx: -4660, seq: 8))
        rig.echo.handle(try rig.probe(.rtt, dx: 0, seq: 9))
        XCTAssertEqual(rig.csv.lines.count, 3)
        for line in rig.csv.lines {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            XCTAssertEqual(fields.count, 6, line)
            XCTAssertFalse(line.contains("4660"), line)
            XCTAssertNotNil(Int(fields[0]), line)
            XCTAssertEqual(fields[2], "41")
            XCTAssertNotNil(Int(fields[3]), line)
            XCTAssertNotNil(Int(fields[4]), line)
            XCTAssertNotNil(Int(fields[5]), line)
        }
        XCTAssertTrue(rig.csv.lines[0].hasPrefix("7,cursor,41,0,0,"))
        XCTAssertTrue(rig.csv.lines[1].hasPrefix("8,cursor,41,0,"))
    }

    func testCounterGapCountsMissingPackets() throws {
        let rig = Rig()
        rig.attachAndStart()
        rig.echo.handle(try rig.probe(.burst, seq: 1))
        _ = try rig.probe(.burst, seq: 2)
        _ = try rig.probe(.burst, seq: 3)
        rig.echo.handle(try rig.probe(.burst, seq: 4))
        XCTAssertTrue(rig.csv.lines[0].hasPrefix("1,burst,41,0,"))
        XCTAssertTrue(rig.csv.lines[1].hasPrefix("4,burst,41,2,"), "two probes never arrived")
    }

    // MARK: Wired to the central and security

    func testEchoThroughCentralAndSecurityAndWriteCompletion() throws {
        let pairKey = SymmetricKey(data: Data(repeating: 0x44, count: 32))
        let rig = SecurityRig(pairKey: pairKey)
        let cursor = CursorSpy()
        let echo = MeasurementEcho(
            write: { [central = rig.central] in central.sendMeasure($0) }, cursor: cursor, flash: FlashSpy(), csv: CSVSpy(),
            noteActivity: {})
        echo.connect(central: rig.central, security: rig.security)
        echo.setMeasureMode(true)
        rig.connect()
        let phone = TestPhone(pairKey: pairKey)
        try rig.authenticate(phone)
        let channels = try XCTUnwrap(phone.handshake.takeChannelSet())

        func probe(_ seq: UInt32) throws -> Data {
            try channels.sealer(.measureP2M).seal(MeasurePayload(kind: .rtt, dxSixteenths: 0, seq: seq, phoneTimeMicros: 9).encode())
        }
        rig.answerOutstandingWrites()
        // A normal control write is issued first, then the reply: write responses come back in that order.
        rig.security.send(.ack(Ack(eventId: UUID(), result: .posted)))
        let before = rig.driver.controlWrites.count
        rig.central.receive(eventData: try probe(1))
        XCTAssertEqual(rig.driver.controlWrites.count, before + 1)
        let reply = try XCTUnwrap(rig.driver.controlWrites.last)
        XCTAssertEqual(reply[0], 0x7E)
        XCTAssertNoThrow(try channels.opener(.measureM2P).open(reply).get())
        // A second probe while the reply is unanswered is skipped.
        rig.central.receive(eventData: try probe(2))
        XCTAssertEqual(rig.driver.controlWrites.count, before + 1)
        // The answer to the normal write does not free the reply's slot.
        rig.central.controlWriteCompleted()
        rig.central.receive(eventData: try probe(3))
        XCTAssertEqual(rig.driver.controlWrites.count, before + 1, "the reply is still unanswered")
        rig.central.controlWriteCompleted()
        rig.central.receive(eventData: try probe(4))
        XCTAssertEqual(rig.driver.controlWrites.count, before + 2)
        // The connection ends: nothing is left attached.
        rig.central.handleLink(.disconnected(rig.peripheral))
        rig.central.receive(eventData: try probe(5))
        XCTAssertEqual(rig.driver.controlWrites.count, before + 2)
    }
}

@MainActor
final class MeasureFlashWindowTests: XCTestCase {
    func testFlashLightsAndTheWindowGoesAwayOnHide() {
        let window = MeasureFlashWindow()
        window.flash()
        XCTAssertFalse(window.isLit, "nothing is shown before show()")
        window.show()
        window.flash()
        XCTAssertTrue(window.isLit)
        window.hide()
        XCTAssertFalse(window.isLit)
    }
}
#endif
