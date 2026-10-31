#if DEBUG
import Foundation
import RemoteKeyboardCore

/// TP1 measurement settings that the keyboard extension cannot get from a launch environment of its own. The host App
/// copies them from its launch environment (set by the UI test) into the App Group, and the extension reads them when
/// a measurement button is pressed. Numbers and names only.
enum MeasureLaunchConfig {
    static let m3SamplesKey = "rk.measure.m3Samples"
    static let m6ScenarioKey = "rk.measure.m6Scenario"
    static let m6SecondsKey = "rk.measure.m6Seconds"
    static let m7RunsKey = "rk.measure.m7Runs"
    static let m8SecondsKey = "rk.measure.m8Seconds"
    static let latencyKey = "rk.measure.latency"

    static let defaultM3Samples = 10_000
    static let defaultM6Seconds = 600
    static let defaultM8Seconds = 600

    private static let environmentNames = [
        m3SamplesKey: "RKMEAS_M3_SAMPLES", m6ScenarioKey: "RKMEAS_M6_SCENARIO", m6SecondsKey: "RKMEAS_M6_SECONDS",
        m7RunsKey: "RKMEAS_M7_RUNS", m8SecondsKey: "RKMEAS_M8_SECONDS", latencyKey: "RKMEAS_LATENCY"
    ]

    /// Host App, at launch: a variable that is not set removes its key, so an earlier run's value never lingers.
    static func apply(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let defaults = UserDefaults(suiteName: AppGroup.identifier) else { return }
        for (key, name) in environmentNames {
            if let value = environment[name], !value.isEmpty { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
    }

    struct Values {
        var m3Samples = MeasureLaunchConfig.defaultM3Samples
        var m6Scenario = "normal"
        var m6Seconds = MeasureLaunchConfig.defaultM6Seconds
        var m7Runs = ModeSwitchPlan.defaultRuns
        var m8Seconds = MeasureLaunchConfig.defaultM8Seconds
        /// `RKMEAS_LATENCY`: low (default), medium or none.
        var latency = MeasureLatencyPreference.default
    }

    /// Extension, when a button is pressed.
    static func read() -> Values {
        var values = Values()
        guard let defaults = UserDefaults(suiteName: AppGroup.identifier) else { return values }
        func number(_ key: String) -> Int? { (defaults.string(forKey: key)).flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } }
        values.m3Samples = number(m3SamplesKey) ?? values.m3Samples
        values.m6Seconds = number(m6SecondsKey) ?? values.m6Seconds
        values.m7Runs = number(m7RunsKey) ?? values.m7Runs
        values.m8Seconds = number(m8SecondsKey) ?? values.m8Seconds
        values.latency = MeasureLatencyPreference(environmentValue: defaults.string(forKey: latencyKey))
        values.m6Scenario = defaults.string(forKey: m6ScenarioKey) ?? values.m6Scenario
        return values
    }
}
#endif
