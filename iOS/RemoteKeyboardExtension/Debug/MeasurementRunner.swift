#if DEBUG
import Foundation
import os
import RemoteKeyboardCore

/// TP1 measurements on the iPhone (Debug builds only): M2 back-pressure, M3 round trip, M5 backlog, M6 heartbeat and the
/// packet side of M4. Every probe is a counter-AEAD packet from the connection's `ChannelSet` (the same sealers every run,
/// so a counter never starts at 1 twice), and every reply is opened with the `measureM2P` opener before it counts.
///
/// - A ciphertext is sealed only when it is handed to `updateValue`. When the radio refuses it the ciphertext is dropped and
///   the probe is sealed again, with the next counter, at the next chance.
/// - `rtt` and `heartbeat` probes wait for their turn when frames of a long text are queued: the peripheral offers them
///   one slot after every `KeyboardBLEPeripheral.interleaveRatio` frames. A probe that has not left by the next tick is
///   replaced by the new one (counted as `superseded`).
/// - Results are numbers only: counts, milliseconds and the names of the runs. No typed text, no coordinates, no `dx`.
@MainActor
final class MeasurementRunner {
    enum Scenario: String {
        case normal, longText, load, covered, interference
    }

    enum Job: Equatable {
        case m2
        case m3(samples: Int)
        case m5(samples: Int)
        case m6(Scenario, seconds: Int)
        case m4
    }

    private enum Phase: Int {
        case baseline, load, recovery
        var name: String { ["baseline", "load", "recovery"][rawValue] }
    }

    private struct Probe {
        var kind: MeasurePayload.Kind
        var seq: UInt32
        var sampleMicros: UInt64
    }

    static let csvHeader = "seq,kind,bytes,counterGap,interArrivalMicros,holdMicros,rttMicros,handoffWaitMicros"
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard", category: "measure")
    private static let rttInterval: TimeInterval = 1.0 / 60
    private static let heartbeatInterval: TimeInterval = 0.1
    private static let longTextInterval: UInt64 = 1_000_000
    private static let baselineMicros: UInt64 = 10_000_000
    private static let settleSeconds: TimeInterval = 1
    private static let m2Rounds = 100
    private static let m2BurstCap = 2000
    private static let m2ReadyTimeout: TimeInterval = 2
    /// A round-trip run stops after this many probes per wanted reply, so a Mac that answers hardly any cannot run forever.
    private static let sentCapFactor = 4
    private static let packetBytes = [16 + 25, 157 + 25]

    unowned let peripheral: KeyboardBLEPeripheral
    private(set) var job: Job?
    /// Progress while a run goes; empty otherwise.
    private(set) var progressText = ""
    /// The last run: its first line is 完成 or 中止, the others are `RKMEAS`-style `key=value` lines.
    private(set) var resultLines: [String] = []
    var onChange: (() -> Void)?

    var isRunning: Bool { job != nil }
    /// Whether the peripheral should offer this runner a packet slot between frames of a long text.
    var wantsInterleave: Bool {
        switch job {
        case .m3?, .m5?, .m6?: true
        default: false
        }
    }
    /// Text for the panel: progress while running, otherwise the last result.
    var displayText: String { isRunning ? progressText : resultLines.joined(separator: "\n") }

    private var seq: UInt32 = 0
    private var pending: Probe?
    private var ticker: Timer?
    private var settleTimer: Timer?
    private var readyTimer: Timer?
    private var finishing = false
    private var startedAt: UInt64 = 0
    private var lastProgressAt: UInt64 = 0
    private var nextLongTextAt: UInt64 = 0

    // Counts shared by the runs.
    private var sent = 0
    private var refused = 0
    private var superseded = 0
    private var texts = 0
    private var blockedMs: [Double] = []
    /// What was known when an `rtt` probe left, by seq, until its reply arrives. The Mac skips probes while a reply is still
    /// unanswered, so entries that never get a reply are dropped once they are far behind (`sentWindow`).
    private struct SentProbe {
        var waitMicros: UInt64
        var phase: Phase
    }
    private static let sentWindow: UInt32 = 256
    private var sentProbes: [UInt32: SentProbe] = [:]
    private var waitMs: [Double] = []
    private var csvRows: [String] = []

    // Round trip (M3, M5).
    private var rttMs: [Phase: [Double]] = [:]
    private var holdMs: [Double] = []
    private var replyCount = 0
    private var replyIntervalsMs: [Double] = []
    private var lastReplyAt: UInt64?
    private var lastReplyCounter: UInt64?
    private var phase = Phase.baseline

    // Heartbeat (M6).
    private var handoffGapsMs: [Double] = []
    private var lastHandoffAt: UInt64?

    // Back-pressure (M2).
    private var m2SizeIndex = 0
    private var m2Round = 0
    private var m2Counts: [[Double]] = [[], []]
    private var m2DrainMs: [[Double]] = [[], []]
    private var m2RefusedAt: UInt64?

    // Cursor packets (M4).
    private var m4FirstMs: [Double] = []
    private var m4PacedMs: [Double] = []
    private var m4Refused = 0
    private var m4Packets = 0

    init(peripheral: KeyboardBLEPeripheral) {
        self.peripheral = peripheral
    }

    private var now: UInt64 { MeasureClock.nowMicros() }

    // MARK: Start and stop

    func start(_ job: Job) {
        guard self.job == nil, peripheral.isMeasureReady else { return }
        reset()
        self.job = job
        startedAt = now
        lastProgressAt = startedAt
        switch job {
        case .m2:
            progressText = "進行中 M2"
            m2Burst()
        case .m3, .m5:
            progressText = "進行中 \(name(of: job))"
            nextLongTextAt = startedAt
            startTicker(Self.rttInterval) { $0.tickRoundTrip() }
        case .m6:
            progressText = "進行中 M6"
            nextLongTextAt = startedAt
            startTicker(Self.heartbeatInterval) { $0.tickHeartbeat() }
        case .m4:
            progressText = "進行中 M4"
        }
        Self.log.info("measure start \(self.name(of: job), privacy: .public)")
        onChange?()
    }

    /// 停止 on the panel, or the end of M4.
    func cancel() {
        guard let job else { return }
        if job == .m4 { finish(reason: nil) } else { finish(reason: "已停止") }
    }

    /// The connection (or its handshake) ended: nothing of a run can go on.
    func connectionEnded() {
        pending = nil
        guard job != nil else { return }
        finish(reason: "連線中斷")
    }

    private func reset() {
        seq = 0
        pending = nil
        finishing = false
        sent = 0
        refused = 0
        superseded = 0
        texts = 0
        blockedMs = []
        sentProbes = [:]
        waitMs = []
        csvRows = []
        rttMs = [:]
        holdMs = []
        replyCount = 0
        replyIntervalsMs = []
        lastReplyAt = nil
        lastReplyCounter = nil
        phase = .baseline
        handoffGapsMs = []
        lastHandoffAt = nil
        m2SizeIndex = 0
        m2Round = 0
        m2Counts = [[], []]
        m2DrainMs = [[], []]
        m2RefusedAt = nil
        m4FirstMs = []
        m4PacedMs = []
        m4Refused = 0
        m4Packets = 0
    }

    private func startTicker(_ interval: TimeInterval, _ fire: @escaping @MainActor (MeasurementRunner) -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if let self { fire(self) } }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTimers() {
        ticker?.invalidate()
        ticker = nil
        settleTimer?.invalidate()
        settleTimer = nil
        readyTimer?.invalidate()
        readyTimer = nil
    }

    // MARK: Hooks from the peripheral

    /// `peripheralManagerIsReady`: the transmit queue has room again.
    func radioReady() {
        if case .m2? = job, let refusedAt = m2RefusedAt {
            readyTimer?.invalidate()
            readyTimer = nil
            m2DrainMs[m2SizeIndex].append(Double(now &- refusedAt) / 1000)
            m2RefusedAt = nil
            m2Burst()
        } else {
            pump()
        }
    }

    /// A slot between two frames of a long text: hands over the waiting probe. `false` when the radio refused it, which
    /// stops the peripheral's drain until the radio is ready again.
    func offerPacket() -> Bool {
        guard pending != nil else { return true }
        return sendPending()
    }

    /// Hands over the waiting probe unless frames are queued (then the peripheral's interleave does it).
    func pump() {
        guard pending != nil, !peripheral.hasQueuedFrames else { return }
        _ = sendPending()
    }

    func noteBlocked(micros: UInt64) {
        guard let job, job != .m2, job != .m4 else { return }
        blockedMs.append(Double(micros) / 1000)
    }

    // MARK: Sending

    private func sendPending() -> Bool {
        guard let probe = pending, let channels = peripheral.measureChannels else { return true }
        let handoff = now
        let payload = MeasurePayload(kind: probe.kind, dxSixteenths: 0, seq: probe.seq, phoneTimeMicros: handoff)
        guard let packet = try? channels.sealer(.measureP2M).seal(payload.encode()) else {
            finish(reason: "加密失敗")
            return true
        }
        guard peripheral.sendChannelPacket(packet) else {
            // The ciphertext is dropped; the probe is sealed again with the next counter.
            refused += 1
            return false
        }
        pending = nil
        sent += 1
        let wait = handoff &- probe.sampleMicros
        waitMs.append(Double(wait) / 1000)
        if probe.kind == .rtt {
            sentProbes[probe.seq] = SentProbe(waitMicros: wait, phase: phase)
            if sentProbes.count > Int(Self.sentWindow) {
                sentProbes = sentProbes.filter { $0.key &+ Self.sentWindow > probe.seq }
            }
        }
        if probe.kind == .heartbeat {
            let gap = lastHandoffAt.map { handoff &- $0 } ?? 0
            if lastHandoffAt != nil { handoffGapsMs.append(Double(gap) / 1000) }
            lastHandoffAt = handoff
            csvRows.append("\(probe.seq),heartbeat,\(packet.count),0,\(gap),0,0,\(wait)")
        }
        return true
    }

    private func queue(_ kind: MeasurePayload.Kind) {
        seq &+= 1
        if pending != nil { superseded += 1 }
        pending = Probe(kind: kind, seq: seq, sampleMicros: now)
        pump()
    }

    private func isStillReady() -> Bool {
        guard peripheral.isMeasureReady else {
            finish(reason: "連線中斷")
            return false
        }
        return true
    }

    // MARK: M3 and M5

    private func target(of job: Job) -> Int {
        switch job {
        case .m3(let samples), .m5(let samples): samples
        default: 0
        }
    }

    private func name(of job: Job) -> String {
        switch job {
        case .m2: "M2"
        case .m3: "M3"
        case .m4: "M4"
        case .m5: "M5"
        case .m6: "M6"
        }
    }

    private func tickRoundTrip() {
        guard let job, !finishing, isStillReady() else { return }
        let target = target(of: job)
        updatePhase(job: job, target: target)
        if case .m5 = job, phase == .load, now >= nextLongTextAt {
            nextLongTextAt = now + Self.longTextInterval
            if peripheral.sendDebugLongText() { texts += 1 }
        }
        queue(.rtt)
        reportProgress("\(name(of: job)) \(replyCount)/\(target)")
        if replyCount >= target || sent >= target * Self.sentCapFactor { beginSettling() }
    }

    private func updatePhase(job: Job, target: Int) {
        guard case .m5 = job else { return }
        if now &- startedAt < Self.baselineMicros {
            phase = .baseline
        } else {
            phase = replyCount < target * 8 / 10 ? .load : .recovery
        }
    }

    /// Replies still on their way are waited for one more second, then the run ends.
    private func beginSettling() {
        guard !finishing else { return }
        finishing = true
        ticker?.invalidate()
        ticker = nil
        pending = nil
        let timer = Timer(timeInterval: Self.settleSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(reason: nil) }
        }
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    /// A reply from the Mac (a control write that starts with the measurement magic), opened before it counts.
    func handleReply(_ data: Data) {
        guard job != nil, let channels = peripheral.measureChannels else { return }
        let opener = channels.opener(.measureM2P)
        guard case .success(let plain) = opener.open(data), let echo = MeasureEchoPayload.decode(plain) else { return }
        let arrival = now
        let rtt = arrival &- echo.phoneTimeMicros
        // The reply counts for the phase in which its probe was sent, not the one in which it arrived.
        let sentInfo = sentProbes.removeValue(forKey: echo.seq)
        rttMs[sentInfo?.phase ?? phase, default: []].append(Double(rtt) / 1000)
        holdMs.append(Double(echo.macHoldMicros) / 1000)
        replyCount += 1
        let interval = lastReplyAt.map { arrival &- $0 } ?? 0
        if lastReplyAt != nil { replyIntervalsMs.append(Double(interval) / 1000) }
        lastReplyAt = arrival
        let counter = opener.lastOpenedCounter
        let gap = lastReplyCounter.map { Int(truncatingIfNeeded: counter) - Int(truncatingIfNeeded: $0) - 1 } ?? 0
        lastReplyCounter = max(counter, lastReplyCounter ?? 0)
        let wait = sentInfo?.waitMicros ?? 0
        csvRows.append("\(echo.seq),rtt,\(data.count),\(gap),\(interval),\(echo.macHoldMicros),\(rtt),\(wait)")
    }

    // MARK: M6

    private func tickHeartbeat() {
        guard case .m6(let scenario, let seconds)? = job, !finishing, isStillReady() else { return }
        if scenario == .longText, now >= nextLongTextAt {
            nextLongTextAt = now + Self.longTextInterval
            if peripheral.sendDebugLongText() { texts += 1 }
        }
        queue(.heartbeat)
        let elapsed = Int((now &- startedAt) / 1_000_000)
        reportProgress("M6 \(elapsed)/\(seconds) s")
        if elapsed >= seconds { beginSettling() }
    }

    // MARK: M2

    private func m2Burst() {
        guard isStillReady(), let channels = peripheral.measureChannels else { return }
        let size = [16, 157][m2SizeIndex]
        var accepted = 0
        var radioFull = false
        while accepted < Self.m2BurstCap {
            seq &+= 1
            let payload = MeasurePayload(kind: .burst, dxSixteenths: 0, seq: seq, phoneTimeMicros: now)
            guard let packet = try? channels.sealer(.measureP2M).seal(payload.encode(padTo: size)) else {
                finish(reason: "加密失敗")
                return
            }
            guard peripheral.sendChannelPacket(packet) else {
                // The refused ciphertext is dropped; the next burst seals with the next counter.
                radioFull = true
                break
            }
            accepted += 1
        }
        m2Counts[m2SizeIndex].append(Double(accepted))
        m2Round += 1
        if m2Round >= Self.m2Rounds {
            m2Round = 0
            m2SizeIndex += 1
        }
        reportProgress("M2 \(Self.packetBytes[min(m2SizeIndex, 1)]) 位元組 \(m2Round)/\(Self.m2Rounds)")
        if m2SizeIndex >= 2 {
            // The last burst's drain time is not waited for.
            finish(reason: nil)
        } else if radioFull {
            m2RefusedAt = now
            let timer = Timer(timeInterval: Self.m2ReadyTimeout, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish(reason: "等不到 ready") }
            }
            RunLoop.main.add(timer, forMode: .common)
            readyTimer = timer
        } else {
            // The queue never filled up (the cap was reached): the next round starts on the next turn of the run loop.
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { if case .m2? = self?.job { self?.m2Burst() } }
            }
        }
    }

    // MARK: M4

    /// One cursor probe from the touch surface. Returns whether the radio took it; when it did not, the surface keeps its
    /// movement and tries again. Only while the M4 job runs. `sampleMicros` is the time of the earliest touch sample the packet carries.
    func sendCursor(dxSixteenths: Int16, sampleMicros: UInt64, isFirstOfStroke: Bool) -> Bool {
        guard job == .m4, peripheral.isMeasureReady, let channels = peripheral.measureChannels else { return false }
        seq &+= 1
        let handoff = now
        let payload = MeasurePayload(kind: .cursor, dxSixteenths: dxSixteenths, seq: seq, phoneTimeMicros: handoff)
        guard let packet = try? channels.sealer(.measureP2M).seal(payload.encode()) else { return false }
        guard peripheral.sendChannelPacket(packet) else {
            m4Refused += 1
            return false
        }
        let wait = handoff &- sampleMicros
        if isFirstOfStroke { m4FirstMs.append(Double(wait) / 1000) } else { m4PacedMs.append(Double(wait) / 1000) }
        m4Packets += 1
        let gap = lastHandoffAt.map { handoff &- $0 } ?? 0
        lastHandoffAt = handoff
        csvRows.append("\(seq),cursor,\(packet.count),0,\(gap),0,0,\(wait)")
        return true
    }

    // MARK: Results

    private func reportProgress(_ text: String) {
        let current = now
        guard current &- lastProgressAt >= 1_000_000 else { return }
        lastProgressAt = current
        progressText = "進行中 \(text)"
        onChange?()
    }

    private func finish(reason: String?) {
        guard let job else { return }
        stopTimers()
        var lines = [reason.map { "中止 \($0)" } ?? "完成"]
        lines += summaryLines(for: job)
        resultLines = lines
        progressText = ""
        pending = nil
        self.job = nil
        writeCSV(for: job)
        for line in lines { Self.log.info("RKMEAS \(line, privacy: .public)") }
        onChange?()
    }

    private func f(_ value: Double) -> String { value.isNaN ? "nan" : String(format: "%.1f", value) }

    private func stats(_ prefix: String, _ samples: [Double]) -> String {
        let s = LatencyStats(samplesMs: samples)
        return "\(prefix)_p50=\(f(s.p50)) \(prefix)_p95=\(f(s.p95)) \(prefix)_p99=\(f(s.p99)) \(prefix)_max=\(f(s.maxMs))"
    }

    private func summaryLines(for job: Job) -> [String] {
        let blocked = LatencyStats(samplesMs: blockedMs)
        switch job {
        case .m2:
            return (0..<2).map { index in
                let counts = LatencyStats(samplesMs: m2Counts[index])
                let drain = LatencyStats(samplesMs: m2DrainMs[index])
                return "M2 packet=\(Self.packetBytes[index]) rounds=\(counts.count) accepted_p50=\(f(counts.p50)) "
                    + "accepted_min=\(f(m2Counts[index].min() ?? .nan)) accepted_max=\(f(counts.maxMs)) "
                    + "drain_p50_ms=\(f(drain.p50)) drain_p95_ms=\(f(drain.p95)) drain_max_ms=\(f(drain.maxMs))"
            }
        case .m3:
            let all = rttMs.values.flatMap { $0 }
            let rtt = LatencyStats(samplesMs: all)
            let arrival = LatencyStats(samplesMs: replyIntervalsMs)
            let wait = LatencyStats(samplesMs: waitMs)
            let skipped = max(0, sent - replyCount)
            return [
                "M3 count=\(rtt.count) p50_ms=\(f(rtt.p50)) p95_ms=\(f(rtt.p95)) p99_ms=\(f(rtt.p99)) jitter_ms=\(f(rtt.jitterMs)) max_ms=\(f(rtt.maxMs))",
                "M3 sent=\(sent) skipped=\(skipped) skipped_pct=\(f(sent == 0 ? .nan : Double(skipped) * 100 / Double(sent))) "
                    + "refused=\(refused) superseded=\(superseded) arrival_sd_ms=\(f(arrival.standardDeviationMs)) "
                    + "hold_p50_ms=\(f(LatencyStats(samplesMs: holdMs).p50)) wait_p50_ms=\(f(wait.p50)) wait_p95_ms=\(f(wait.p95))"
            ]
        case .m5:
            var lines = [Phase.baseline, .load, .recovery].map { phase -> String in
                let samples = rttMs[phase] ?? []
                let extra = phase == .load ? " texts=\(texts)" : ""
                return "M5 phase=\(phase.name) count=\(samples.count) \(stats("rtt", samples))\(extra)"
            }
            let loaded = rttMs[.load] ?? []
            let quarter = max(1, loaded.count / 4)
            let trend = loaded.count >= 4
                ? LatencyStats(samplesMs: Array(loaded.suffix(quarter))).p50 - LatencyStats(samplesMs: Array(loaded.prefix(quarter))).p50
                : Double.nan
            lines.append(
                "M5 trend_p50_ms=\(f(trend)) blocked_count=\(blocked.count) blocked_p50_ms=\(f(blocked.p50)) "
                    + "blocked_p95_ms=\(f(blocked.p95)) blocked_max_ms=\(f(blocked.maxMs)) sent=\(sent) "
                    + "skipped=\(max(0, sent - replyCount)) refused=\(refused) superseded=\(superseded)")
            return lines
        case .m6(let scenario, let seconds):
            let gaps = LatencyStats(samplesMs: handoffGapsMs)
            return [
                "M6 scenario=\(scenario.rawValue) seconds=\(seconds) sent=\(sent) superseded=\(superseded) refused=\(refused) texts=\(texts)",
                "M6 handoff_gap_p50_ms=\(f(gaps.p50)) handoff_gap_p99_ms=\(f(gaps.p99)) handoff_gap_max_ms=\(f(gaps.maxMs)) "
                    + "blocked_count=\(blocked.count) blocked_max_ms=\(f(blocked.maxMs))"
            ]
        case .m4:
            let first = LatencyStats(samplesMs: m4FirstMs)
            let paced = LatencyStats(samplesMs: m4PacedMs)
            return [
                "M4 packets=\(m4Packets) refused=\(m4Refused) strokes=\(first.count)",
                "M4 first_wait_p50_ms=\(f(first.p50)) first_wait_p95_ms=\(f(first.p95)) paced_wait_p50_ms=\(f(paced.p50)) "
                    + "paced_wait_p95_ms=\(f(paced.p95)) paced_wait_p99_ms=\(f(paced.p99))"
            ]
        }
    }

    /// The run's rows go to the Extension's temporary directory: sizes, counters and times, nothing else.
    private func writeCSV(for job: Job) {
        guard !csvRows.isEmpty else { return }
        let stamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory.appending(path: "measure-\(name(of: job))-\(stamp).csv", directoryHint: .notDirectory)
        let text = ([Self.csvHeader] + csvRows).joined(separator: "\n") + "\n"
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            Self.log.info("measure csv rows=\(self.csvRows.count, privacy: .public)")
        } catch {
            Self.log.error("measure csv write failed code \((error as NSError).code, privacy: .public)")
        }
    }
}
#endif
