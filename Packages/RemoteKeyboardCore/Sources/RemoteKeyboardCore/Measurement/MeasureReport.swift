#if DEBUG
import Foundation

/// The wording of the result lines (`key=value` words after an item name). One-way numbers are estimates and carry `est_`;
/// the watchdog result is a 模擬誤釋放 (`simulated_release`); the click number is a 點擊代理 RTT (`click_proxy_rtt_…`), the
/// round trip of a measurement packet and not of a real click.
public enum MeasureReport {
    public static func number(_ value: Double) -> String { value.isNaN ? "nan" : String(format: "%.1f", value) }

    private static func integer(_ value: Double) -> String { value.isNaN ? "nan" : String(format: "%.0f", value) }

    /// M3a: the round trip.
    public static func m3a(rtt: LatencyStats) -> String {
        "M3a count=\(rtt.count) p50_ms=\(number(rtt.p50)) p95_ms=\(number(rtt.p95)) p99_ms=\(number(rtt.p99)) "
            + "jitter_ms=\(number(rtt.jitterMs)) max_ms=\(number(rtt.maxMs))"
    }

    /// M3b: how many probes got a reply. Says how representative M3a is; it is not a performance number.
    public static func m3b(
        sent: Int, replies: Int, refused: Int, superseded: Int, arrivalSdMs: Double, holdP50Ms: Double, waitP50Ms: Double, waitP95Ms: Double
    ) -> String {
        let skipped = max(0, sent - replies)
        let coverage = sent == 0 ? Double.nan : Double(replies) * 100 / Double(sent)
        let skippedPct = sent == 0 ? Double.nan : Double(skipped) * 100 / Double(sent)
        return "M3b sent=\(sent) replies=\(replies) coverage_pct=\(number(coverage)) skipped=\(skipped) skipped_pct=\(number(skippedPct)) "
            + "refused=\(refused) superseded=\(superseded) arrival_sd_ms=\(number(arrivalSdMs)) hold_p50_ms=\(number(holdP50Ms)) "
            + "wait_p50_ms=\(number(waitP50Ms)) wait_p95_ms=\(number(waitP95Ms))"
    }

    /// M3c: the estimated one-way delay, with the three parts of the estimate side by side.
    public static func m3c(_ analysis: ClockOffsetAnalysis?) -> String {
        guard let analysis else {
            return "M3c 估計單程 est_oneway_p50_ms=nan est_oneway_p95_ms=nan est_oneway_p99_ms=nan assumption=symmetric unavailable=no_usable_replies"
        }
        let stats = LatencyStats(samplesMs: analysis.estimatedOneWayMicros.map { $0 / 1000 })
        return "M3c 估計單程 est_oneway_p50_ms=\(number(stats.p50)) est_oneway_p95_ms=\(number(stats.p95)) "
            + "est_oneway_p99_ms=\(number(stats.p99)) " + modelWords(analysis)
    }

    /// The clock model of a run (calibration for M7 and M8), enough to rebuild it from the line.
    public static func calibration(_ analysis: ClockOffsetAnalysis?, label: String) -> String {
        guard let analysis else { return "\(label) unavailable=no_usable_replies assumption=symmetric" }
        return "\(label) " + modelWords(analysis)
    }

    private static func modelWords(_ analysis: ClockOffsetAnalysis) -> String {
        "offset_est_us=\(integer(analysis.offsetEstimate.micros)) ref_phone_us=\(integer(analysis.offsetEstimate.atPhoneMicros)) "
            + "drift_us_per_min=\(number(analysis.assumptions.driftMicrosPerMinute)) drift_measured=\(analysis.assumptions.driftMeasured) "
            + "error_bound_ms=\(number(analysis.errorBound.totalMicros / 1000)) samples=\(analysis.assumptions.sampleCount) assumption=symmetric"
    }

    /// M8: the round trip of the `rtt` probes that stand in for clicks.
    public static func clickProxy(rtt: LatencyStats) -> String {
        "M8 點擊代理 RTT count=\(rtt.count) click_proxy_rtt_p50_ms=\(number(rtt.p50)) click_proxy_rtt_p95_ms=\(number(rtt.p95)) "
            + "click_proxy_rtt_p99_ms=\(number(rtt.p99))"
    }

    /// The iPhone does not know how many heartbeats arrived late at the Mac; that number comes from the Mac's CSV.
    public static func simulatedReleasePending(item: String) -> String {
        "\(item) 模擬誤釋放 simulated_release=pending_mac_csv"
    }

    /// The connection latency that was requested, on every line of a run. `confirmed` is always `unconfirmed`: nothing on the
    /// phone can read the interval.
    public static func tag(_ line: String, latency: MeasureLatencyPreference, carryover: String?) -> String {
        var result = "\(line) latency_requested=\(latency.name) latency_confirmed=unconfirmed"
        if let carryover { result += " latency_carryover=\(carryover)" }
        return result
    }
}
#endif
