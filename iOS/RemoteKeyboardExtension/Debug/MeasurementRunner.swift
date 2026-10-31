#if DEBUG
import Foundation
import os
import RemoteKeyboardCore

/// TP1 measurements on the iPhone (Debug builds only): M2 back-pressure, M3 round trip and estimated one-way delay, M5
/// backlog, M6 heartbeat, M7 mode switch, M8 touchpad workload and the packet side of M4. Every probe is a counter-AEAD
/// packet from the connection's `ChannelSet` (the same sealers every run, so a counter never starts at 1 twice), and every
/// reply is opened with the `measureM2P` opener before it counts.
///
/// - A ciphertext is sealed only when it is handed to `updateValue`. When the radio refuses it the ciphertext is dropped and
///   the probe is sealed again, with the next counter, at the next chance.
/// - A run that interleaves (M3, M5, M6, M7, M8) hands its probes over through `TransmitInterleave`: while frames of a long
///   text are queued, the peripheral offers one probe after every `TransmitInterleave.ratio` frames (keyboard mode) or one
///   frame after every `ratio` probes (touchpad mode, used by M7 after the switch). There is one waiting probe per kind; a
///   probe that has not left by the time the next one of its kind is made is replaced (counted as `superseded`).
/// - Before a run asks for anything it requests the connection latency (`RKMEAS_LATENCY`, default `.low`), with five seconds
///   of 60 Hz traffic before the request and seven after it. The Mac's CSV gives the arrival-interval change as supporting
///   evidence; whether the interval really changed is only known from PacketLogger, so every result line says
///   `latency_confirmed=unconfirmed`.
/// - One-way numbers are estimates (M3c): they come from the clock model of `ClockOffsetEstimator` and are labelled `est_`.
///   M7 and M8 cursor packets are timed at the Mac; their estimate is made afterwards from the Mac's CSV and the `CAL` line.
/// - Results are numbers only: counts, milliseconds and the names of the runs. No typed text, no coordinates, no `dx`.
@MainActor
final class MeasurementRunner {
    enum Scenario: String {
        case normal, longText, load, covered, interference
    }

    enum Job: Equatable {
        case m2
        case m3(samples: Int)
        case m5
        case m6(Scenario, seconds: Int)
        case m4
        case m7(runs: Int)
        case m8(seconds: Int)
    }

    /// Where a run is: the traffic before and after the latency request, the clock calibration at the start and end of M7 and
    /// M8, and the run itself.
    private enum Stage: Equatable {
        case prelude, calibrationStart, main, calibrationEnd
    }

    private struct Probe {
        var kind: MeasurePayload.Kind
        var seq: UInt32
        var sampleMicros: UInt64
    }

    /// What was known when an `rtt` probe left, by seq, until its reply arrives. The Mac skips probes while a reply is still
    /// unanswered, so entries that never get a reply are dropped once they are far behind (`sentWindow`).
    private struct SentProbe {
        var waitMicros: UInt64
        var m5Phase: M5Phase?
        var stage: Stage
    }

    /// One round of M7.
    private struct ModeSwitchRound {
        var baselineSeqs: ClosedRange<UInt32>?
        var trackpadSeqs: ClosedRange<UInt32>?
        var textSentAt: UInt64?
        var textAccepted = false
        var queueEmptyAt: UInt64?
        var frameTimes: [UInt64] = []
        var frames: FrameRate.Summary?
    }

    static let csvHeader = "seq,kind,bytes,counterGap,interArrivalMicros,holdMicros,rttMicros,handoffWaitMicros"
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard", category: "measure")
    private static let rttInterval: TimeInterval = 1.0 / 60
    private static let heartbeatInterval: TimeInterval = 0.1
    private static let workloadTick: TimeInterval = 0.004
    private static let longTextInterval: UInt64 = 1_000_000
    private static let settleSeconds: TimeInterval = 1
    private static let calibrationMicros: UInt64 = 5_000_000
    /// M7 waits for a long text that is still being sent for this long after a round's pause, then goes on.
    private static let m7DrainLimitMicros: UInt64 = 10_000_000
    private static let m2Rounds = 100
    private static let m2BurstCap = 2000
    private static let m2ReadyTimeout: TimeInterval = 2
    /// A round-trip run stops after this many probes per wanted reply, so a Mac that answers hardly any cannot run forever.
    private static let sentCapFactor = 4
    private static let packetBytes = [16 + 25, 157 + 25]
    private static let sentWindow: UInt32 = 256

    unowned let peripheral: KeyboardBLEPeripheral
    private(set) var job: Job?
    /// Progress while a run goes; empty otherwise.
    private(set) var progressText = ""
    /// The last run: its first line is 完成 or 中止, the others are `RKMEAS`-style `key=value` lines.
    private(set) var resultLines: [String] = []
    var onChange: (() -> Void)?
    /// Keyboard mode by default; M7 switches the exit to touchpad mode for the ten seconds after the switch.
    private(set) var transmitMode = TransmitInterleave.Mode.keyboard

    var isRunning: Bool { job != nil }
    /// Whether the peripheral should offer this runner a packet slot between frames of a long text.
    var wantsInterleave: Bool {
        switch job {
        case .m3?, .m5?, .m6?, .m7?, .m8?: true
        default: false
        }
    }
    /// A probe is waiting for the peripheral to hand it over.
    var hasWaitingPacket: Bool { !pending.isEmpty }
    /// Text for the panel: progress while running, otherwise the last result.
    var displayText: String { isRunning ? progressText : resultLines.joined(separator: "\n") }

    private var seq: UInt32 = 0
    private var pending: [Probe] = []
    private var ticker: Timer?
    private var settleTimer: Timer?
    private var readyTimer: Timer?
    private var finishing = false
    private var stage = Stage.main
    private var startedAt: UInt64 = 0
    private var stageStartedAt: UInt64 = 0
    private var lastProgressAt: UInt64 = 0
    private var nextLongTextAt: UInt64 = 0

    // Connection latency.
    private var latency = MeasureLatencyPreference.default
    private var latencyRequestedAt: UInt64?
    private var latencyCarryover: String?

    // Counts shared by the runs.
    private var sent = 0
    private var refused = 0
    private var superseded = 0
    private var texts = 0
    private var blockedMs: [Double] = []
    private var sentProbes: [UInt32: SentProbe] = [:]
    private var waitMs: [Double] = []
    private var csvRows: [String] = []

    // Round trip (M3, M5, M8 clicks).
    private var rttAll: [Double] = []
    private var rttByPhase: [M5Phase: [Double]] = [:]
    private var rttSeries: [(sentMicros: UInt64, rttMs: Double)] = []
    private var clickProxyMs: [Double] = []
    private var offsetSamples: [(stage: Stage, sample: ClockOffsetSample)] = []
    private var holdMs: [Double] = []
    private var replyCount = 0
    private var replyIntervalsMs: [Double] = []
    private var lastReplyAt: UInt64?
    private var lastReplyCounter: UInt64?
    private var m5Phase = M5Phase.baseline
    private var m5TextStoppedAt: UInt64?
    private var m5QueueEmptyAt: UInt64?

    // Heartbeat (M6, M8).
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

    // Workloads (M7, M8).
    private var pacer = Pacer()
    private var streams = M8Streams()
    private var mainStartedAt: UInt64 = 0
    private var bodySeqs: ClosedRange<UInt32>?
    private var m7Rounds: [ModeSwitchRound] = []
    private var m7Current = ModeSwitchRound()
    private var m7Index = 0
    private var m7RoundStartedAt: UInt64 = 0
    private var m7Switched = false
    private var m7Finalized = false

    init(peripheral: KeyboardBLEPeripheral) {
        self.peripheral = peripheral
    }

    private var now: UInt64 { MeasureClock.nowMicros() }

    // MARK: Start and stop

    func start(_ job: Job, latency: MeasureLatencyPreference = .default) {
        guard self.job == nil, peripheral.isMeasureReady else { return }
        reset()
        self.job = job
        self.latency = latency
        let started = now
        startedAt = started
        stageStartedAt = started
        lastProgressAt = started
        progressText = "進行中 \(name(of: job))"
        Self.log.info("measure start \(self.name(of: job), privacy: .public) latency \(latency.name, privacy: .public)")
        if job == .m4 {
            // M4 is driven by a person: the request goes out at once and there is no traffic before it.
            requestLatency()
            beginRun()
        } else if latency.isRequested {
            stage = .prelude
            progressText = "進行中 延遲偏好 \(latency.name)"
            startTicker(Self.rttInterval) { $0.tickPrelude() }
        } else {
            latencyCarryover = peripheral.latencyCarryover
            beginRun()
        }
        onChange?()
    }

    /// 停止 on the panel, or the end of M4.
    func cancel() {
        guard let job else { return }
        if job == .m4 { finish(reason: nil) } else { finish(reason: "已停止") }
    }

    /// The connection (or its handshake) ended: nothing of a run can go on.
    func connectionEnded() {
        pending = []
        guard job != nil else { return }
        finish(reason: "連線中斷")
    }

    private func reset() {
        seq = 0
        pending = []
        finishing = false
        stage = .main
        latencyRequestedAt = nil
        latencyCarryover = nil
        transmitMode = .keyboard
        resetCounts()
        m2SizeIndex = 0
        m2Round = 0
        m2Counts = [[], []]
        m2DrainMs = [[], []]
        m2RefusedAt = nil
        m4FirstMs = []
        m4PacedMs = []
        m4Refused = 0
        m4Packets = 0
        pacer = Pacer()
        streams = M8Streams()
        bodySeqs = nil
        m7Rounds = []
        m7Current = ModeSwitchRound()
        m7Index = 0
        m7Switched = false
        m7Finalized = false
        m5TextStoppedAt = nil
        m5QueueEmptyAt = nil
        offsetSamples = []
    }

    /// The counts of the run itself, cleared again when the traffic before the latency request is over.
    private func resetCounts() {
        sent = 0
        refused = 0
        superseded = 0
        texts = 0
        blockedMs = []
        sentProbes = [:]
        waitMs = []
        csvRows = []
        rttAll = []
        rttByPhase = [:]
        rttSeries = []
        clickProxyMs = []
        holdMs = []
        replyCount = 0
        replyIntervalsMs = []
        lastReplyAt = nil
        lastReplyCounter = nil
        m5Phase = .baseline
        handoffGapsMs = []
        lastHandoffAt = nil
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

    // MARK: Latency request

    private func requestLatency() {
        guard latency.isRequested else {
            latencyCarryover = peripheral.latencyCarryover
            return
        }
        let at = now
        if peripheral.requestMeasureLatency(latency) { latencyRequestedAt = at }
    }

    /// Five seconds of 60 Hz traffic, the request, and seven more seconds of it (two to settle, five to measure). The run
    /// starts when that is over.
    private func tickPrelude() {
        guard job != nil, stage == .prelude, !finishing, isStillReady() else { return }
        let current = now
        let window = UInt64(MeasureLatencyPreference.evidenceWindowSeconds) * 1_000_000
        let settle = UInt64(MeasureLatencyPreference.settleSeconds) * 1_000_000
        if latencyRequestedAt == nil, current &- startedAt >= window {
            requestLatency()
            if latencyRequestedAt == nil {
                finish(reason: "無法要求連線延遲")
                return
            }
        }
        if let at = latencyRequestedAt, current &- at >= settle + window {
            beginRun()
            return
        }
        queue(.burst)
        reportProgress("延遲偏好 \(latency.name)")
    }

    // MARK: Begin a run

    /// The run proper: its counts start from zero (the traffic before the latency request is not part of it).
    private func beginRun() {
        guard let job else { return }
        stopTimers()
        pending = []
        resetCounts()
        stage = .main
        let current = now
        startedAt = current
        stageStartedAt = current
        mainStartedAt = current
        lastProgressAt = current
        nextLongTextAt = current
        progressText = "進行中 \(name(of: job))"
        switch job {
        case .m2:
            m2Burst()
        case .m3, .m5:
            startTicker(Self.rttInterval) { $0.tickRoundTrip() }
        case .m6:
            startTicker(Self.heartbeatInterval) { $0.tickHeartbeat() }
        case .m4:
            break
        case .m7, .m8:
            stage = .calibrationStart
            pacer = Pacer()
            startTicker(Self.workloadTick) { $0.tickWorkload() }
        }
        onChange?()
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

    /// A slot between two frames of a long text: hands over the oldest waiting probe. `false` when the radio refused it,
    /// which stops the peripheral's drain until the radio is ready again.
    func offerPacket() -> Bool {
        guard !pending.isEmpty else { return true }
        return sendNext()
    }

    /// Hands over the waiting probes unless frames are queued (then the peripheral's exit rule decides).
    func pump() {
        guard !pending.isEmpty else { return }
        if peripheral.hasQueuedFrames {
            if wantsInterleave { peripheral.drainQueuedFrames() }
            return
        }
        while !pending.isEmpty {
            guard sendNext() else { return }
        }
    }

    func noteBlocked(micros: UInt64) {
        guard let job, job != .m2, job != .m4 else { return }
        blockedMs.append(Double(micros) / 1000)
    }

    /// One `0x02` frame of a long text was handed to the radio.
    func noteFrameHanded() {
        guard case .m7? = job, m7Current.textSentAt != nil else { return }
        m7Current.frameTimes.append(now)
    }

    /// The last frame of the queue was handed to the radio: nothing of a long text waits any more.
    func noteQueueEmpty() {
        let current = now
        switch job {
        case .m5?:
            if m5TextStoppedAt != nil, m5QueueEmptyAt == nil { m5QueueEmptyAt = current }
        case .m7?:
            if m7Current.textSentAt != nil, m7Current.queueEmptyAt == nil { m7Current.queueEmptyAt = current }
        default:
            break
        }
    }

    // MARK: Sending

    private func oldestPendingIndex() -> Int? {
        pending.indices.min { pending[$0].sampleMicros < pending[$1].sampleMicros }
    }

    /// Seals and hands over the oldest waiting probe. `false` when the radio refused it (the probe stays, to be sealed
    /// again with the next counter); `true` otherwise, including when there was nothing that could be sent.
    private func sendNext() -> Bool {
        guard let index = oldestPendingIndex() else { return true }
        guard let channels = peripheral.measureChannels else {
            pending = []
            return true
        }
        let probe = pending[index]
        let handoff = now
        let payload = MeasurePayload(kind: probe.kind, dxSixteenths: 0, seq: probe.seq, phoneTimeMicros: handoff)
        guard let packet = try? channels.sealer(.measureP2M).seal(payload.encode()) else {
            pending = []
            finish(reason: "加密失敗")
            return true
        }
        guard peripheral.sendChannelPacket(packet) else {
            // The ciphertext is dropped; the probe is sealed again with the next counter.
            refused += 1
            return false
        }
        pending.remove(at: index)
        sent += 1
        let wait = handoff &- probe.sampleMicros
        waitMs.append(Double(wait) / 1000)
        if probe.kind == .rtt {
            sentProbes[probe.seq] = SentProbe(waitMicros: wait, m5Phase: job == .m5 ? m5Phase : nil, stage: stage)
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

    /// Makes a probe of a kind; one that is still waiting for its turn is replaced.
    private func queue(_ kind: MeasurePayload.Kind) {
        seq &+= 1
        let probe = Probe(kind: kind, seq: seq, sampleMicros: now)
        if let index = pending.firstIndex(where: { $0.kind == kind }) {
            superseded += 1
            pending[index] = probe
        } else {
            pending.append(probe)
        }
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

    private func name(of job: Job) -> String {
        switch job {
        case .m2: "M2"
        case .m3: "M3"
        case .m4: "M4"
        case .m5: "M5"
        case .m6: "M6"
        case .m7: "M7"
        case .m8: "M8"
        }
    }

    private func tickRoundTrip() {
        guard let job, !finishing, isStillReady() else { return }
        let current = now
        if case .m5 = job {
            guard let phase = M5Timeline.phase(atElapsedMicros: current &- startedAt) else {
                beginSettling()
                return
            }
            m5Phase = phase
            if phase == .load, current >= nextLongTextAt {
                nextLongTextAt = current + Self.longTextInterval
                if peripheral.sendDebugLongText() { texts += 1 }
            }
            if phase == .recovery, m5TextStoppedAt == nil {
                m5TextStoppedAt = current
                if !peripheral.hasQueuedFrames { m5QueueEmptyAt = current }
            }
            queue(.rtt)
            let total = M5Timeline.baselineSeconds + M5Timeline.loadSeconds + M5Timeline.recoverySeconds
            reportProgress("M5 \((current &- startedAt) / 1_000_000)/\(total) s")
            return
        }
        guard case .m3(let target) = job else { return }
        queue(.rtt)
        reportProgress("M3 \(replyCount)/\(target)")
        if replyCount >= target || sent >= target * Self.sentCapFactor { beginSettling() }
    }

    /// Replies still on their way are waited for one more second, then the run ends.
    private func beginSettling() {
        guard !finishing else { return }
        finishing = true
        ticker?.invalidate()
        ticker = nil
        pending = []
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
        // The reply counts for the stretch in which its probe was sent, not the one in which it arrived.
        let sentInfo = sentProbes.removeValue(forKey: echo.seq)
        let rttMilliseconds = Double(rtt) / 1000
        rttAll.append(rttMilliseconds)
        if let phase = sentInfo?.m5Phase { rttByPhase[phase, default: []].append(rttMilliseconds) }
        rttSeries.append((echo.phoneTimeMicros, rttMilliseconds))
        if case .m8? = job, sentInfo?.stage == .main { clickProxyMs.append(rttMilliseconds) }
        offsetSamples.append((
            sentInfo?.stage ?? stage,
            ClockOffsetSample(
                phoneSendMicros: echo.phoneTimeMicros, macRecvMicros: echo.macTimeMicros, phoneRecvMicros: arrival,
                macHoldMicros: UInt64(echo.macHoldMicros))))
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

    // MARK: M7 and M8

    private func tickWorkload() {
        guard let job, !finishing, isStillReady() else { return }
        let current = now
        switch stage {
        case .calibrationStart, .calibrationEnd:
            calibrate(current)
        case .main:
            switch job {
            case .m7(let runs): tickModeSwitch(current, runs: runs)
            case .m8(let seconds): tickWorkloadBody(current, seconds: seconds)
            default: break
            }
        case .prelude:
            break
        }
    }

    /// Five seconds of 60 Hz round trips, so the clock model has samples without any load on the link.
    private func calibrate(_ current: UInt64) {
        if pacer.due(atMicros: current, interval: M8Streams.cursorIntervalMicros) { queue(.rtt) }
        reportProgress(stage == .calibrationStart ? "校時 開始" : "校時 結束")
        guard current &- stageStartedAt >= Self.calibrationMicros else { return }
        pacer = Pacer()
        if stage == .calibrationStart {
            stage = .main
            stageStartedAt = current
            mainStartedAt = current
            m7RoundStartedAt = current
        } else {
            beginSettling()
        }
    }

    private func endMain(_ current: UInt64) {
        stage = .calibrationEnd
        stageStartedAt = current
        pacer = Pacer()
        transmitMode = .keyboard
    }

    private func tickWorkloadBody(_ current: UInt64, seconds: Int) {
        let elapsed = current &- mainStartedAt
        guard elapsed < UInt64(seconds) * 1_000_000 else {
            endMain(current)
            return
        }
        for kind in streams.due(atElapsedMicros: elapsed) {
            queue(kind)
            bodySeqs = bodySeqs.map { $0.lowerBound...seq } ?? seq...seq
        }
        reportProgress("M8 \(elapsed / 1_000_000)/\(seconds) s")
    }

    private func tickModeSwitch(_ current: UInt64, runs: Int) {
        guard m7Index < runs else {
            endMain(current)
            return
        }
        let elapsed = current &- m7RoundStartedAt
        switch ModeSwitchPlan.stage(atIterationMicros: elapsed) {
        case .baseline?:
            if paceCursor(current) { m7Current.baselineSeqs = extend(m7Current.baselineSeqs) }
        case .trackpad?:
            if !m7Switched { switchToTrackpad(current) }
            if paceCursor(current) { m7Current.trackpadSeqs = extend(m7Current.trackpadSeqs) }
        case .rest?:
            if m7Switched, !m7Finalized { finalizeTrackpad() }
        case nil:
            let planned = UInt64(ModeSwitchPlan.baselineSeconds + ModeSwitchPlan.trackpadSeconds + ModeSwitchPlan.restSeconds) * 1_000_000
            if peripheral.hasQueuedFrames, elapsed < planned + Self.m7DrainLimitMicros { return }
            completeRound(current)
        }
        reportProgress("M7 \(min(m7Index + 1, runs))/\(runs)")
    }

    /// The seq range of a stretch, grown by the probe that was just made.
    private func extend(_ seqs: ClosedRange<UInt32>?) -> ClosedRange<UInt32> {
        seqs.map { $0.lowerBound...seq } ?? seq...seq
    }

    /// A cursor packet at 60 Hz. It carries no distance: nothing moves on the Mac. Returns whether one was made.
    private func paceCursor(_ current: UInt64) -> Bool {
        guard pacer.due(atMicros: current, interval: M8Streams.cursorIntervalMicros) else { return false }
        queue(.cursor)
        return true
    }

    /// The long text goes out in keyboard mode and the exit turns to touchpad mode at once, without waiting for the text.
    private func switchToTrackpad(_ current: UInt64) {
        m7Current.textSentAt = current
        let accepted = peripheral.sendDebugLongText()
        m7Current.textAccepted = accepted
        if accepted { texts += 1 }
        transmitMode = .trackpad
        m7Switched = true
    }

    private func finalizeTrackpad() {
        transmitMode = .keyboard
        m7Finalized = true
        guard let textSentAt = m7Current.textSentAt else { return }
        m7Current.frames = FrameRate.summarize(
            frameMicros: m7Current.frameTimes, windowStartMicros: textSentAt, windowSeconds: ModeSwitchPlan.trackpadSeconds,
            queueEmptyAtMicros: m7Current.queueEmptyAt)
    }

    private func completeRound(_ current: UInt64) {
        if m7Switched, !m7Finalized { finalizeTrackpad() }
        m7Rounds.append(m7Current)
        m7Current = ModeSwitchRound()
        m7Index += 1
        m7Switched = false
        m7Finalized = false
        m7RoundStartedAt = current
        pacer = Pacer()
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
        transmitMode = .keyboard
        var lines = [reason.map { "中止 \($0)" } ?? "完成"]
        lines += (summaryLines(for: job) + latencyLines()).map {
            MeasureReport.tag($0, latency: latency, carryover: latency.isRequested ? nil : latencyCarryover)
        }
        resultLines = lines
        progressText = ""
        pending = []
        self.job = nil
        writeCSV(for: job)
        for line in lines { Self.log.info("RKMEAS \(line, privacy: .public)") }
        onChange?()
    }

    /// When the request was made, so the Mac's CSV can be searched for the arrival intervals before and after it.
    private func latencyLines() -> [String] {
        let at = latencyRequestedAt.map { String($0) } ?? "none"
        return [
            "LAT request_phone_us=\(at) settle_s=\(MeasureLatencyPreference.settleSeconds) "
                + "window_s=\(MeasureLatencyPreference.evidenceWindowSeconds) evidence=mac_csv_burst_rows"
        ]
    }

    private func f(_ value: Double) -> String { MeasureReport.number(value) }

    private func stats(_ prefix: String, _ samples: [Double]) -> String {
        let s = LatencyStats(samplesMs: samples)
        return "\(prefix)_p50=\(f(s.p50)) \(prefix)_p95=\(f(s.p95)) \(prefix)_p99=\(f(s.p99)) \(prefix)_max=\(f(s.maxMs))"
    }

    private func range(_ seqs: ClosedRange<UInt32>?) -> String {
        seqs.map { "\($0.lowerBound)..\($0.upperBound)" } ?? "none"
    }

    /// The clock model of the whole run, and of its start and end separately (their difference shows the drift).
    private func calibrationLines() -> [String] {
        func analysis(_ stages: [Stage]) -> ClockOffsetAnalysis? {
            ClockOffsetEstimator.analyze(offsetSamples.filter { stages.contains($0.stage) }.map { $0.sample })
        }
        return [
            MeasureReport.calibration(analysis([.calibrationStart, .main, .calibrationEnd]), label: "CAL"),
            MeasureReport.calibration(analysis([.calibrationStart]), label: "CAL_START"),
            MeasureReport.calibration(analysis([.calibrationEnd]), label: "CAL_END")
        ]
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
            let arrival = LatencyStats(samplesMs: replyIntervalsMs)
            let wait = LatencyStats(samplesMs: waitMs)
            return [
                MeasureReport.m3a(rtt: LatencyStats(samplesMs: rttAll)),
                MeasureReport.m3b(
                    sent: sent, replies: replyCount, refused: refused, superseded: superseded, arrivalSdMs: arrival.standardDeviationMs,
                    holdP50Ms: LatencyStats(samplesMs: holdMs).p50, waitP50Ms: wait.p50, waitP95Ms: wait.p95),
                MeasureReport.m3c(ClockOffsetEstimator.analyze(offsetSamples.map { $0.sample }))
            ]
        case .m5:
            return m5Lines(blocked: blocked)
        case .m6(let scenario, let seconds):
            let gaps = LatencyStats(samplesMs: handoffGapsMs)
            return [
                "M6 scenario=\(scenario.rawValue) seconds=\(seconds) sent=\(sent) superseded=\(superseded) refused=\(refused) texts=\(texts)",
                "M6 handoff_gap_p50_ms=\(f(gaps.p50)) handoff_gap_p99_ms=\(f(gaps.p99)) handoff_gap_max_ms=\(f(gaps.maxMs)) "
                    + "blocked_count=\(blocked.count) blocked_max_ms=\(f(blocked.maxMs))",
                MeasureReport.simulatedReleasePending(item: "M6")
            ]
        case .m4:
            let first = LatencyStats(samplesMs: m4FirstMs)
            let paced = LatencyStats(samplesMs: m4PacedMs)
            return [
                "M4 packets=\(m4Packets) refused=\(m4Refused) strokes=\(first.count)",
                "M4 first_wait_p50_ms=\(f(first.p50)) first_wait_p95_ms=\(f(first.p95)) paced_wait_p50_ms=\(f(paced.p50)) "
                    + "paced_wait_p95_ms=\(f(paced.p95)) paced_wait_p99_ms=\(f(paced.p99))"
            ]
        case .m7(let runs):
            return m7Lines(runs: runs)
        case .m8(let seconds):
            let gaps = LatencyStats(samplesMs: handoffGapsMs)
            return [
                "M8 seconds=\(seconds) body_seq=\(range(bodySeqs)) sent=\(sent) superseded=\(superseded) refused=\(refused)",
                MeasureReport.clickProxy(rtt: LatencyStats(samplesMs: clickProxyMs)),
                "M8 heartbeat_handoff_gap_p99_ms=\(f(gaps.p99)) heartbeat_handoff_gap_max_ms=\(f(gaps.maxMs)) "
                    + "blocked_count=\(blocked.count) blocked_max_ms=\(f(blocked.maxMs))",
                MeasureReport.simulatedReleasePending(item: "M8"),
                "M8 est_oneway=from_mac_csv (scripts/tp1-oneway-stats)"
            ] + calibrationLines()
        }
    }

    private func m5Lines(blocked: LatencyStats) -> [String] {
        var lines = M5Phase.allCases.map { phase -> String in
            let samples = rttByPhase[phase] ?? []
            let extra = phase == .load ? " texts=\(texts)" : ""
            return "M5 phase=\(phase.name) count=\(samples.count) \(stats("rtt", samples))\(extra)"
        }
        let loaded = rttByPhase[.load] ?? []
        let quarter = max(1, loaded.count / 4)
        let trend = loaded.count >= 4
            ? LatencyStats(samplesMs: Array(loaded.suffix(quarter))).p50 - LatencyStats(samplesMs: Array(loaded.prefix(quarter))).p50
            : Double.nan
        lines.append(
            "M5 trend_p50_ms=\(f(trend)) blocked_count=\(blocked.count) blocked_p50_ms=\(f(blocked.p50)) "
                + "blocked_p95_ms=\(f(blocked.p95)) blocked_max_ms=\(f(blocked.maxMs)) sent=\(sent) "
                + "skipped=\(max(0, sent - replyCount)) refused=\(refused) superseded=\(superseded)")
        // Time from the end of the text to an empty 0x02 queue, and from there to a round trip back at the baseline's P95.
        var drain = "nan"
        var recover = "nan"
        if let stopped = m5TextStoppedAt {
            if let emptied = m5QueueEmptyAt {
                drain = f(Double(M5Timeline.drainMicros(textStoppedAt: stopped, queueEmptyAt: emptied)) / 1000)
                let baselineP95 = LatencyStats(samplesMs: rttByPhase[.baseline] ?? []).p95
                let micros = M5Timeline.recoverMicros(samples: rttSeries, drainedAtMicros: emptied, baselineP95Ms: baselineP95)
                recover = micros.map { f(Double($0) / 1000) } ?? "never"
            } else {
                drain = "not_empty"
            }
        }
        let counts = Dictionary(uniqueKeysWithValues: M5Phase.allCases.map { ($0, rttByPhase[$0]?.count ?? 0) })
        let valid = M5Timeline.isValid(counts: counts)
        lines.append(
            "M5 drain_ms=\(drain) recover_ms=\(recover) recover_run=\(M5Timeline.recoveryRunLength) "
                + "min_samples=\(M5Timeline.minimumSamplesPerPhase) valid=\(valid)")
        return lines
    }

    private func m7Lines(runs: Int) -> [String] {
        var lines: [String] = []
        var starvedTotal = 0
        var minFrames: Int?
        for (index, round) in m7Rounds.enumerated() {
            let summary = round.frames
            starvedTotal += summary?.starvedSeconds ?? 0
            if let low = summary?.minPerSecond { minFrames = min(minFrames ?? low, low) }
            let textMs = round.textSentAt.flatMap { start in round.queueEmptyAt.map { Double($0 &- start) / 1000 } } ?? .nan
            let perSecond = summary.map { $0.perSecond.map(String.init).joined(separator: "/") } ?? "none"
            lines.append(
                "M7 round=\(index + 1) baseline_seq=\(range(round.baselineSeqs)) trackpad_seq=\(range(round.trackpadSeqs)) "
                    + "text_accepted=\(round.textAccepted) text_send_ms=\(f(textMs)) text_complete=\(round.queueEmptyAt != nil) "
                    + "frames_per_s_min=\(summary?.minPerSecond.map(String.init) ?? "none") starved_s=\(summary?.starvedSeconds ?? 0) "
                    + "frames_per_s=\(perSecond)")
        }
        lines.insert(
            "M7 rounds=\(m7Rounds.count)/\(runs) baseline_s=\(ModeSwitchPlan.baselineSeconds) trackpad_s=\(ModeSwitchPlan.trackpadSeconds) "
                + "texts=\(texts) frames_per_s_min=\(minFrames.map(String.init) ?? "none") starved_s_total=\(starvedTotal) "
                + "sent=\(sent) superseded=\(superseded) refused=\(refused)", at: 0)
        lines.append("M7 est_oneway=from_mac_csv (scripts/tp1-oneway-stats) long_text_check=mac_csv")
        return lines + calibrationLines()
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
