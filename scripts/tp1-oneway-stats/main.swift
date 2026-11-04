import Foundation

// TP1 M3c, M6, M7, M8: what only the Mac's CSV and the iPhone's printed lines can tell together.
//
//   swiftc -DDEBUG -o /tmp/rk-oneway \
//     Packages/RemoteKeyboardCore/Sources/RemoteKeyboardCore/Measurement/*.swift scripts/tp1-oneway-stats/main.swift
//   /tmp/rk-oneway <rkmeas.txt> <mac-measure.csv> [--run N]
//
// <rkmeas.txt> holds the `RKMEAS ...` lines of one run (the XCUITest prints them and attaches measure-<item>.txt); <mac-measure.csv>
// is `~/Library/Logs/RemoteKeyboard/measure-<date>.csv`. The CSV holds several runs one after the other; the last one is read
// unless `--run N` (1-based) says otherwise. The files hold numbers and kind names only.
//
// Every one-way number is an ESTIMATE: Mac arrival time minus iPhone send time minus the clock offset of the `CAL` line, which
// assumes the delay is the same each way. Its error bound is `error_bound_ms` of that line; the numbers are not measurements.
// The same code as the app's tests reads the rows (Core's MeasureCSVRecord, ClockOffsetModel, OneWayAnalysis, SimulatedRelease).

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func words(_ line: String) -> [String: String] {
    var result: [String: String] = [:]
    for part in line.split(separator: " ") {
        let pair = part.split(separator: "=", maxSplits: 1)
        if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
    }
    return result
}

func seqRange(_ text: String?) -> ClosedRange<UInt32>? {
    guard let text, let parts = Optional(text.components(separatedBy: "..")), parts.count == 2,
          let low = UInt32(parts[0]), let high = UInt32(parts[1]), low <= high else { return nil }
    return low...high
}

func f(_ value: Double) -> String { MeasureReport.number(value) }

func statsWords(_ prefix: String, _ samples: [Double]) -> String {
    let s = LatencyStats(samplesMs: samples)
    return "\(prefix)_p50_ms=\(f(s.p50)) \(prefix)_p95_ms=\(f(s.p95)) \(prefix)_p99_ms=\(f(s.p99)) n=\(s.count)"
}

var arguments = Array(CommandLine.arguments.dropFirst())
var runNumber: Int?
if let index = arguments.firstIndex(of: "--run"), index + 1 < arguments.count {
    runNumber = Int(arguments[index + 1])
    arguments.removeSubrange(index...(index + 1))
}
guard arguments.count == 2 else { fail("usage: rk-oneway <rkmeas.txt> <mac-measure.csv> [--run N]") }
guard let phoneText = try? String(contentsOfFile: arguments[0], encoding: .utf8) else { fail("cannot read \(arguments[0])") }
guard let csvText = try? String(contentsOfFile: arguments[1], encoding: .utf8) else { fail("cannot read \(arguments[1])") }

let phoneLines = phoneText.split(separator: "\n").map { line -> String in
    let text = String(line)
    return text.hasPrefix("RKMEAS ") ? String(text.dropFirst(7)) : text
}
let rows = csvText.split(separator: "\n").compactMap { MeasureCSVRecord(line: String($0)) }
let runs = MeasureCSVRecord.runs(in: rows)
guard !runs.isEmpty else { fail("no rows in \(arguments[1])") }
let chosen = (runNumber ?? runs.count) - 1
guard runs.indices.contains(chosen) else { fail("run \(chosen + 1) does not exist; the file has \(runs.count)") }
let run = runs[chosen]
print("CSV run \(chosen + 1) of \(runs.count): \(run.count) rows")

guard let calLine = phoneLines.last(where: { $0.hasPrefix("CAL ") }), let model = ClockOffsetModel(parsing: calLine) else {
    fail("no usable `CAL` line in \(arguments[0]): the clock model is missing (only M7 and M8 print one)")
}
let model_ = words(calLine)
let bound = model_["error_bound_ms"] ?? "nan"
print("MODEL assumption=symmetric error_bound_ms=\(bound) drift_us_per_min=\(model_["drift_us_per_min"] ?? "nan") drift_measured=\(model_["drift_measured"] ?? "nan")")

if model_["drift_measured"] != "true" {
    print("WARNING drift_measured=false: no drift could be measured, so the clock offset is taken as constant over the run and "
        + "error_bound_ms carries a 100 ppm allowance over the span instead. Read the estimates with that bound.")
}
// The calibration at the start and at the end give two anchors of their own; their offsets over the time between them are
// the drift that the fitted line of the CAL line should agree with.
if let startLine = phoneLines.last(where: { $0.hasPrefix("CAL_START ") }), let endLine = phoneLines.last(where: { $0.hasPrefix("CAL_END ") }),
   let start = ClockOffsetModel(parsing: startLine), let end = ClockOffsetModel(parsing: endLine),
   end.referencePhoneMicros > start.referencePhoneMicros {
    let minutes = (end.referencePhoneMicros - start.referencePhoneMicros) / 60_000_000
    print("CAL_CHECK start_end_drift_us_per_min=\(f((end.offsetMicros - start.offsetMicros) / minutes)) "
        + "line_drift_us_per_min=\(model_["drift_us_per_min"] ?? "nan") apart_s=\(f(minutes * 60))")
}

// Connection latency: the arrival intervals of the burst rows before and after the request.
if let line = phoneLines.first(where: { $0.hasPrefix("LAT ") }), let request = UInt64(words(line)["request_phone_us"] ?? "") {
    let shift = ArrivalShift.measure(rows: run, requestPhoneMicros: request)
    print("LAT arrival_interval_before_ms=\(f(shift.beforeMedianMs)) arrival_interval_after_ms=\(f(shift.afterMedianMs)) "
        + "change_ms=\(f(shift.changeMs)) n_before=\(shift.beforeCount) n_after=\(shift.afterCount) "
        + "evidence=supporting_only latency_confirmed=unconfirmed")
} else {
    print("LAT no request was made in this run")
}

if let line = phoneLines.first(where: { $0.hasPrefix("M8 seconds=") }) {
    let body = seqRange(words(line)["body_seq"])
    let cursor = OneWayAnalysis.estimatedOneWayMs(rows: run, kind: .cursor, seqRange: body, using: model)
    print("M8 cursor 估計單程 \(statsWords("est_oneway", cursor))")
    let inBody = run.filter { row in row.kind == .heartbeat && (body?.contains(row.seq) ?? true) }
    let release = SimulatedRelease.count(in: inBody)
    print("M8 模擬誤釋放 simulated_release=\(release.count) heartbeat_gaps=\(release.gaps) max_gap_ms=\(f(Double(release.maxGapMicros) / 1000))")
}

if phoneLines.contains(where: { $0.hasPrefix("M6 scenario=") }) {
    let release = SimulatedRelease.count(in: run)
    print("M6 模擬誤釋放 simulated_release=\(release.count) heartbeat_gaps=\(release.gaps) max_gap_ms=\(f(Double(release.maxGapMicros) / 1000))")
}

let roundLines = phoneLines.filter { $0.hasPrefix("M7 round=") }
if !roundLines.isEmpty {
    var passes = 0
    var judged = 0
    for line in roundLines {
        let values = words(line)
        guard let baselineSeqs = seqRange(values["baseline_seq"]), let trackpadSeqs = seqRange(values["trackpad_seq"]) else {
            print("M7 round=\(values["round"] ?? "?") no cursor packets were made")
            continue
        }
        let baseline = OneWayAnalysis.estimatedOneWayMs(rows: run, kind: .cursor, seqRange: baselineSeqs, using: model)
        let after = run.filter { $0.kind == .cursor && trackpadSeqs.contains($0.seq) }.sorted { $0.seq < $1.seq }
        guard let first = after.first else {
            print("M7 round=\(values["round"] ?? "?") \(statsWords("baseline_est_oneway", baseline)) first_after=none")
            continue
        }
        let firstMs = OneWayAnalysis.estimatedOneWayMs(rows: [first], kind: .cursor, seqRange: nil, using: model)[0]
        let firstSecond = after.filter { $0.phoneTimeMicros <= first.phoneTimeMicros + 1_000_000 }
        let firstSecondMs = OneWayAnalysis.estimatedOneWayMs(rows: firstSecond, kind: .cursor, seqRange: nil, using: model)
        let pass = ModeSwitchVerdict.passes(baselineMs: baseline, firstAfterMs: firstMs)
        judged += 1
        if pass { passes += 1 }
        print("M7 round=\(values["round"] ?? "?") \(statsWords("baseline_est_oneway", baseline)) first_after_est_oneway_ms=\(f(firstMs)) "
            + "\(statsWords("first_second_est_oneway", firstSecondMs)) first_within_2x_baseline_p99=\(pass) "
            + "frames_per_s_min=\(values["frames_per_s_min"] ?? "?") text_send_ms=\(values["text_send_ms"] ?? "?")")
    }
    let matched = run.filter { $0.kind == .longTextMatch }.count
    let mismatched = run.filter { $0.kind == .longTextMismatch }.count
    print("M7 rounds=\(roundLines.count) judged=\(judged) first_within_2x_baseline_p99=\(passes)/\(judged) "
        + "long_text_match=\(matched) long_text_mismatch=\(mismatched) texts_sent=\(roundLines.count) "
        + "long_text_complete=\(matched == roundLines.count && mismatched == 0)")
}
