import Foundation

// TP1 M4: statistics from the frame numbers read off the 240 fps video (spec section 13.3).
//
//   swift scripts/tp1-m4-stats.swift <frames.csv> <fps> [target-ms]
//
// The CSV has the header `trial,t0,t2,t5p,t6` and one row per stroke. The four columns after `trial` are frame numbers:
//   t0   first frame in which the finger has moved at least 1 pixel
//   t2   first frame in which the iPhone test surface is white   (may be empty)
//   t5p  first frame in which the Mac corner window is white     (may be empty)
//   t6   first frame in which the Mac cursor has moved
// Lines that start with # and empty lines are ignored. The file holds frame numbers only.
//
// The percentiles are the same as `LatencyStats` in RemoteKeyboardCore: linear interpolation, rank = p x (n - 1).
// `target-ms` is the gate (default 60). A P95 within two frames of it is borderline and needs at least 200 strokes.

struct Stats {
    let count: Int
    let p50, p95, p99: Double

    init(_ samples: [Double]) {
        count = samples.count
        let sorted = samples.sorted()
        func percentile(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return .nan }
            let rank = p * Double(sorted.count - 1)
            let low = Int(rank.rounded(.down))
            let high = min(low + 1, sorted.count - 1)
            return sorted[low] + (rank - Double(low)) * (sorted[high] - sorted[low])
        }
        p50 = percentile(0.50)
        p95 = percentile(0.95)
        p99 = percentile(0.99)
    }

    var jitter: Double { p95 - p50 }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func text(_ value: Double) -> String { value.isNaN ? "     -" : String(format: "%6.1f", value) }

let arguments = CommandLine.arguments
guard arguments.count >= 3, let fps = Double(arguments[2]), fps > 0 else {
    fail("用法：swift scripts/tp1-m4-stats.swift <frames.csv> <fps> [target-ms]")
}
let target = arguments.count > 3 ? (Double(arguments[3]) ?? 60) : 60
guard let content = try? String(contentsOfFile: arguments[1], encoding: .utf8) else { fail("讀不到 \(arguments[1])") }

let frameMs = 1000 / fps
var e2e: [Double] = []
var transport: [Double] = []
var macDisplay: [Double] = []
var rows = 0
var rejected = 0

for line in content.split(whereSeparator: \.isNewline) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.lowercased().hasPrefix("trial") { continue }
    rows += 1
    let fields = trimmed.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
    guard fields.count >= 5, let t0 = Int(fields[1]), let t6 = Int(fields[4]), t6 >= t0 else {
        rejected += 1
        continue
    }
    e2e.append(Double(t6 - t0) * frameMs)
    if let t2 = Int(fields[2]), t6 >= t2 { transport.append(Double(t6 - t2) * frameMs) }
    if let t5p = Int(fields[3]), t6 >= t5p { macDisplay.append(Double(t6 - t5p) * frameMs) }
}

print(String(format: "fps %.1f，每幀 %.2f ms，單點量化誤差 ±%.2f ms，兩點相減最大 ±%.2f ms", fps, frameMs, frameMs / 2, frameMs))
print("資料列 \(rows)，有效 \(e2e.count)，剔除 \(rejected)")
print("   n    P50    P95    P99 jitter（ms）  指標")
for (name, samples) in [("E2E (T6-T0)", e2e), ("傳輸到畫面 (T6-T2)", transport), ("Mac 畫面 (T6-T5')", macDisplay)] {
    let s = Stats(samples)
    print("\(String(format: "%4d", s.count)) \(text(s.p50)) \(text(s.p95)) \(text(s.p99)) \(text(s.jitter))       \(name)")
}

let gate = Stats(e2e)
guard gate.count > 0 else { fail("沒有有效資料列") }
let band = 2 * frameMs
let borderline = abs(gate.p95 - target) <= band
print(String(format: "關卡 P95 < %.0f ms：E2E P95 = %.1f ms（%@）", target, gate.p95, gate.p95 < target ? "低於目標" : "未低於目標"))
print(String(format: "邊界（|P95 - %.0f| <= 2 幀 = %.2f ms）：%@", target, band, borderline ? "是" : "否"))
if borderline && gate.count < 200 { print("邊界且筆數不足 200（目前 \(gate.count)）：需補量到 200 筆再判定") }
if !borderline && gate.count < 100 { print("筆數不足 100（目前 \(gate.count)）") }
