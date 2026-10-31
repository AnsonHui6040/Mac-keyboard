#if DEBUG
import XCTest
@testable import RemoteKeyboardCore

/// The after-the-run side of M3c, M6, M7 and M8: the Mac's CSV rows joined with what the iPhone printed.
final class MeasureAnalysisTests: XCTestCase {
    // MARK: CSV rows

    func testHeaderAndRoundTrip() {
        XCTAssertEqual(
            MeasureCSVRecord.header, "seq,kind,bytes,counterGap,interArrivalMicros,holdMicros,phoneTimeMicros,macTimeMicros")
        let record = MeasureCSVRecord(
            seq: 7, kind: .cursor, bytes: 41, counterGap: 2, interArrivalMicros: 16_700, holdMicros: 0,
            phoneTimeMicros: 123_456_789, macTimeMicros: 987_654_321)
        XCTAssertEqual(record.line, "7,cursor,41,2,16700,0,123456789,987654321")
        XCTAssertEqual(MeasureCSVRecord(line: record.line), record)
    }

    func testRejectsLinesThatAreNotRows() {
        XCTAssertNil(MeasureCSVRecord(line: MeasureCSVRecord.header))
        XCTAssertNil(MeasureCSVRecord(line: ""))
        XCTAssertNil(MeasureCSVRecord(line: "1,cursor,41,0,0,0,5"), "an old 6-column row has no Mac time")
        XCTAssertNil(MeasureCSVRecord(line: "1,mystery,41,0,0,0,5,6"))
        XCTAssertNil(MeasureCSVRecord(line: "x,cursor,41,0,0,0,5,6"))
    }

    func testRowFieldsAreNumbersAndKindNamesOnly() {
        for kind in MeasureCSVRecord.Kind.allCases {
            let line = MeasureCSVRecord(seq: 1, kind: kind, bytes: 41, counterGap: 0, interArrivalMicros: 0, holdMicros: 0, phoneTimeMicros: 1, macTimeMicros: 2).line
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            XCTAssertEqual(fields.count, 8)
            XCTAssertNil(Int(fields[1]), "the kind is a name")
            for index in [0, 2, 3, 4, 5, 6, 7] { XCTAssertNotNil(Int(fields[index]), line) }
        }
        XCTAssertEqual(MeasureCSVRecord.Kind.allCases.map(\.rawValue).sorted(),
                       ["burst", "cursor", "heartbeat", "longTextMatch", "longTextMismatch", "rtt"])
    }

    // MARK: Runs

    private func row(_ seq: UInt32, _ kind: MeasureCSVRecord.Kind, phone: UInt64 = 0, mac: UInt64 = 0, inter: Int = 0) -> MeasureCSVRecord {
        MeasureCSVRecord(seq: seq, kind: kind, bytes: 41, counterGap: 0, interArrivalMicros: inter, holdMicros: 0, phoneTimeMicros: phone, macTimeMicros: mac)
    }

    func testRunsSplitWhereTheSeqGoesBackAndLongTextRowsStayWhereTheyArrived() {
        let rows = [row(1, .cursor), row(2, .cursor), row(0, .longTextMatch), row(3, .cursor), row(1, .heartbeat), row(2, .heartbeat)]
        let runs = MeasureCSVRecord.runs(in: rows)
        XCTAssertEqual(runs.map(\.count), [4, 2])
        XCTAssertEqual(runs[0][2].kind, .longTextMatch)
        XCTAssertEqual(MeasureCSVRecord.runs(in: []).count, 0)
    }

    // MARK: Estimated one-way delay of the Mac's rows

    func testEstimatedOneWayOfCursorRowsUsesTheClockModel() throws {
        // The model: Mac clock = phone clock + 1,000,000 µs, drift-free, from a symmetric 4 ms / 4 ms round trip.
        let samples = (0..<400).map { index -> ClockOffsetSample in
            let send = UInt64(1_000_000 + index * 100_000)
            return ClockOffsetSample(phoneSendMicros: send, macRecvMicros: send + 4_000 + 1_000_000, phoneRecvMicros: send + 8_000)
        }
        let analysis = try XCTUnwrap(ClockOffsetEstimator.analyze(samples))
        // Cursor rows that took 6 ms, 9 ms and 30 ms.
        let rows = [
            row(10, .cursor, phone: 5_000_000, mac: 5_000_000 + 1_000_000 + 6_000),
            row(11, .cursor, phone: 5_016_667, mac: 5_016_667 + 1_000_000 + 9_000),
            row(12, .heartbeat, phone: 5_100_000, mac: 5_100_000 + 1_000_000 + 1_000),
            row(13, .cursor, phone: 5_033_333, mac: 5_033_333 + 1_000_000 + 30_000)
        ]
        let all = OneWayAnalysis.estimatedOneWayMs(rows: rows, kind: .cursor, seqRange: nil, using: analysis)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0], 6, accuracy: 0.01)
        XCTAssertEqual(all[1], 9, accuracy: 0.01)
        XCTAssertEqual(all[2], 30, accuracy: 0.01)
        let some = OneWayAnalysis.estimatedOneWayMs(rows: rows, kind: .cursor, seqRange: 11...12, using: analysis)
        XCTAssertEqual(some.count, 1)
        XCTAssertEqual(some[0], 9, accuracy: 0.01)
    }

    func testTheModelCanBeRebuiltFromThePrintedNumbers() throws {
        let samples = (0..<600).map { index -> ClockOffsetSample in
            let send = UInt64(1_000_000 + index * 100_000)
            // 40 ppm of drift on top of a 2 s offset.
            let macRecv = (Double(send) + 4_000) * 1.00004 + 2_000_000
            return ClockOffsetSample(phoneSendMicros: send, macRecvMicros: UInt64(macRecv.rounded()), phoneRecvMicros: send + 8_000)
        }
        let analysis = try XCTUnwrap(ClockOffsetEstimator.analyze(samples))
        let printed = MeasureReport.calibration(analysis, label: "CAL")
        let model = try XCTUnwrap(ClockOffsetModel(parsing: printed))
        let probe = analysis.offsetMicros(atPhoneMicros: 40_000_000)
        XCTAssertEqual(model.offsetMicros(atPhoneMicros: 40_000_000), probe, accuracy: 1.0, "the numbers on the line are enough to rebuild the model")
    }

    // MARK: Simulated release

    func testSimulatedReleasesAreGapsOverTheWatchdogInsideARun() {
        XCTAssertEqual(SimulatedRelease.watchdogMicros, 350_000)
        let times: [UInt64] = [0, 100_000, 200_000, 600_000, 700_000, 1_050_000, 1_400_001]
        let rows = times.enumerated().map { row(UInt32($0.offset + 1), .heartbeat, mac: $0.element) }
        let result = SimulatedRelease.count(in: rows)
        XCTAssertEqual(result.count, 2, "400 ms and 350.001 ms are over 350 ms; 350 ms exactly is not")
        XCTAssertEqual(result.maxGapMicros, 400_000)
        XCTAssertEqual(result.gaps, 6)
    }

    func testSimulatedReleaseIgnoresOtherKindsAndBetweenRuns() {
        let rows = [row(1, .heartbeat, mac: 0), row(2, .cursor, mac: 1_000_000), row(3, .heartbeat, mac: 100_000)]
        XCTAssertEqual(SimulatedRelease.count(in: rows).count, 0, "the cursor row does not matter, only heartbeats are compared")
        // A second run starts again at seq 1, hours later: not a gap.
        let twoRuns = [row(1, .heartbeat, mac: 0), row(2, .heartbeat, mac: 100_000), row(1, .heartbeat, mac: 50_000_000)]
        XCTAssertEqual(SimulatedRelease.count(in: twoRuns).count, 0)
    }

    // MARK: Connection latency evidence

    func testArrivalIntervalMedianBeforeAndAfterTheRequest() {
        let request: UInt64 = 100_000_000
        var rows: [MeasureCSVRecord] = []
        // 5 s before: 30 ms apart (about 33 Hz). Then 2 s of settling at 20 ms. Then 5 s at 16.7 ms.
        for step in 0..<166 { rows.append(row(UInt32(step + 1), .burst, phone: request - 5_000_000 + UInt64(step) * 30_000, inter: 30_000)) }
        for step in 0..<100 { rows.append(row(UInt32(200 + step), .burst, phone: request + UInt64(step) * 20_000, inter: 20_000)) }
        for step in 0..<300 { rows.append(row(UInt32(400 + step), .burst, phone: request + 2_000_000 + UInt64(step) * 16_667, inter: 16_667)) }
        rows.append(row(900, .cursor, phone: request + 3_000_000, inter: 1))
        let shift = ArrivalShift.measure(rows: rows, requestPhoneMicros: request)
        XCTAssertEqual(shift.beforeMedianMs, 30, accuracy: 0.01)
        XCTAssertEqual(shift.afterMedianMs, 16.667, accuracy: 0.01)
        XCTAssertEqual(shift.beforeCount, 166)
        XCTAssertEqual(shift.afterCount, 300)
        XCTAssertEqual(shift.changeMs, -13.333, accuracy: 0.01)
    }

    func testArrivalIntervalWithoutRowsIsNaN() {
        let shift = ArrivalShift.measure(rows: [], requestPhoneMicros: 1_000)
        XCTAssertTrue(shift.beforeMedianMs.isNaN)
        XCTAssertTrue(shift.changeMs.isNaN)
        XCTAssertEqual(shift.beforeCount, 0)
    }

    // MARK: M7 verdict

    func testModeSwitchPassesWhenTheFirstPacketIsWithinTwiceTheBaselineP99() {
        let baseline = (0..<600).map { 10 + Double($0 % 20) }   // 10...29 ms
        let p99 = LatencyStats(samplesMs: baseline).p99
        XCTAssertTrue(ModeSwitchVerdict.passes(baselineMs: baseline, firstAfterMs: p99 * 2))
        XCTAssertFalse(ModeSwitchVerdict.passes(baselineMs: baseline, firstAfterMs: p99 * 2 + 0.1))
        XCTAssertFalse(ModeSwitchVerdict.passes(baselineMs: [], firstAfterMs: 5), "no baseline, no verdict")
        XCTAssertFalse(ModeSwitchVerdict.passes(baselineMs: baseline, firstAfterMs: .nan))
    }
}
#endif
