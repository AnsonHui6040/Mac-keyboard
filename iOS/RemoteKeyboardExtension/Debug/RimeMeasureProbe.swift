#if DEBUG
import Foundation
import RemoteKeyboardCore
import os

/// DEBUG measurement of the Quick engine inside the keyboard extension: the time of each Quick key, the peak
/// `phys_footprint`, the smallest `os_proc_available_memory()`, the `.bin` files in the staging folder and whether the
/// App Group file `rime-probe.txt` can be read. The values live in the extension process, so they carry over when the
/// keyboard appears again (also after a switch to handwriting). Numbers only: no key, code or candidate is recorded.
@MainActor
final class RimeMeasureProbe {
    static let shared = RimeMeasureProbe()

    private static let megabyte = 1_048_576.0
    private static let sampleInterval: TimeInterval = 0.5
    private static let publishInterval: TimeInterval = 0.25

    private var durationsUs: [Int] = []
    private var engine: QuickEngine?
    private var footprintPeakMB = 0.0
    private var availableMinMB = Double.infinity
    private var timer: Timer?
    private var lastPublish = Date.distantPast
    private var publish: ((String) -> Void)?
    private var owner: ObjectIdentifier?
    private var appGroupRead = false

    /// The staging folder of librime: the keyboard container's `Application Support/rime/user/build`.
    private let stagingURL: URL? = try? FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        .appendingPathComponent("rime/user/build", isDirectory: true)

    /// Which engine the Quick page loaded; the line stays hidden until then.
    func setEngine(_ value: QuickEngine) {
        engine = value
        sampleMemory()
        publishNow()
    }

    /// Times one Quick key; the closure runs the engine call and returns what it returned.
    func measure<T>(_ body: () -> T) -> T {
        let began = DispatchTime.now().uptimeNanoseconds
        let result = body()
        durationsUs.append(Int((DispatchTime.now().uptimeNanoseconds - began) / 1_000))
        publishThrottled()
        return result
    }

    /// Starts the 0.5 s memory sampling while the keyboard is visible; `publish` receives the new line text.
    /// Only the controller that started the sampling can stop it, so a late disappear of an older controller does nothing.
    func start(owner: ObjectIdentifier, publish: @escaping (String) -> Void) {
        self.owner = owner
        self.publish = publish
        timer?.invalidate()
        appGroupRead = Self.appGroupReadsOK()
        sampleMemory()
        let tick = Timer(timeInterval: Self.sampleInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                RimeMeasureProbe.shared.sampleMemory()
                RimeMeasureProbe.shared.publishNow()
            }
        }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
        publishNow()
    }

    func stop(owner: ObjectIdentifier) {
        guard self.owner == owner else { return }
        self.owner = nil
        timer?.invalidate()
        timer = nil
        publish = nil
    }

    // MARK: Values

    private func sampleMemory() {
        if let footprint = Self.physFootprintBytes() {
            footprintPeakMB = max(footprintPeakMB, Double(footprint) / Self.megabyte)
        }
        availableMinMB = min(availableMinMB, Double(os_proc_available_memory()) / Self.megabyte)
    }

    private func publishThrottled() {
        guard Date().timeIntervalSince(lastPublish) >= Self.publishInterval else { return }
        publishNow()
    }

    private func publishNow() {
        guard let publish, let line = currentLine() else { return }
        lastPublish = Date()
        publish(line.text)
    }

    private func currentLine() -> RimeMeasureLine? {
        guard let engine else { return nil }
        let stats = LatencyStats(samplesMs: durationsUs.map { Double($0) / 1_000 })
        return RimeMeasureLine(
            engine: engine, keys: durationsUs.count,
            p50Us: stats.count == 0 ? 0 : Int((stats.p50 * 1_000).rounded()),
            p95Us: stats.count == 0 ? 0 : Int((stats.p95 * 1_000).rounded()),
            footprintPeakMB: footprintPeakMB,
            availableMinMB: availableMinMB.isFinite ? availableMinMB : 0,
            stagingBins: stagingBinCount(), appGroupRead: appGroupRead)
    }

    private func stagingBinCount() -> Int {
        guard let stagingURL,
              let names = try? FileManager.default.contentsOfDirectory(atPath: stagingURL.path) else { return 0 }
        return names.filter { $0.hasSuffix(".bin") }.count
    }

    /// The host App writes `rime-probe.txt` (content `ok`) into the App Group container; the keyboard must read it.
    private static func appGroupReadsOK() -> Bool {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier),
              let text = try? String(contentsOf: root.appendingPathComponent("rime-probe.txt"), encoding: .utf8)
        else { return false }
        return text == "ok"
    }

    private static func physFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : nil
    }
}
#endif
