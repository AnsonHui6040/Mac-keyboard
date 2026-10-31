#if DEBUG
import Foundation
import OSLog
import RemoteKeyboardCore

/// Moves the Mac's test cursor for the M4 measurement. One call per cursor probe.
@MainActor
protocol MeasureCursorMoving: AnyObject {
    func move(byPoints dx: Double)
}

/// The corner window that turns white for the M4 measurement.
@MainActor
protocol MeasureFlashing: AnyObject {
    /// The window exists only while measurement mode is on.
    func setActive(_ active: Bool)
    func flash()
}

@MainActor
protocol MeasureCSVSink: AnyObject {
    func append(_ line: String)
    func flush()
}

/// The measurement CSV: one row per accepted probe, integers and a kind name only. There is no text, no cursor position
/// and no `dx` in it. The row layout lives in `MeasureCSVRecord` (Core), which the after-the-run analysis reads back.
///
/// `holdMicros` is how long the Mac held an `rtt` probe before it wrote the reply, -1 when the probe was not answered
/// (a reply was still unanswered, or the write was refused) and 0 for the other kinds. `counterGap` is the number of
/// packets between this one and the one before it that never arrived, 0 for the first packet of a run. `phoneTimeMicros`
/// is the iPhone's clock as the probe carried it and `macTimeMicros` the Mac's clock when it arrived; the two clocks are
/// never the same clock. A long text that arrived adds one row (`longTextMatch` or `longTextMismatch`) with its length in
/// `bytes` and no seq.
enum MeasureCSV {
    static let header = MeasureCSVRecord.header

    static func line(
        seq: UInt32, kind: MeasurePayload.Kind, bytes: Int, counterGap: Int, interArrivalMicros: Int, holdMicros: Int,
        phoneTimeMicros: UInt64, macTimeMicros: UInt64
    ) -> String {
        MeasureCSVRecord(
            seq: seq, kind: MeasureCSVRecord.Kind(kind), bytes: bytes, counterGap: counterGap, interArrivalMicros: interArrivalMicros,
            holdMicros: holdMicros, phoneTimeMicros: phoneTimeMicros, macTimeMicros: macTimeMicros
        ).line
    }

    static func longTextLine(check: MeasureLongText.Check, utf8Length: Int, macTimeMicros: UInt64) -> String {
        MeasureCSVRecord(
            seq: 0, kind: check == .match ? .longTextMatch : .longTextMismatch, bytes: utf8Length, counterGap: 0,
            interArrivalMicros: 0, holdMicros: 0, phoneTimeMicros: 0, macTimeMicros: macTimeMicros
        ).line
    }
}

/// Appends the rows to `~/Library/Logs/RemoteKeyboard/measure-<date>.csv` (with the header when the file is new), in
/// batches so a 60 Hz run does not write 60 times a second. Rows that are waiting when the traffic stops are written after
/// `idleFlushSeconds`, so the end of a run is in the file without waiting for the next batch.
@MainActor
final class MeasureCSVFile: MeasureCSVSink {
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard.receiver", category: "measure")
    private static let batchSize = 200

    static var defaultFileURL: URL {
        let day = Date.now.formatted(.iso8601.year().month().day())
        return URL.libraryDirectory.appending(path: "Logs/RemoteKeyboard/measure-\(day).csv", directoryHint: .notDirectory)
    }

    let fileURL: URL
    private let idleFlushSeconds: Double
    private var pending: [String] = []
    private var idleFlush: Task<Void, Never>?

    init(fileURL: URL, idleFlushSeconds: Double = 1) {
        self.fileURL = fileURL
        self.idleFlushSeconds = idleFlushSeconds
    }

    func append(_ line: String) {
        pending.append(line)
        if pending.count >= Self.batchSize {
            flush()
            return
        }
        idleFlush?.cancel()
        idleFlush = Task { [weak self, idleFlushSeconds] in
            try? await Task.sleep(for: .seconds(idleFlushSeconds))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        idleFlush?.cancel()
        idleFlush = nil
        guard !pending.isEmpty else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            var text = pending.joined(separator: "\n") + "\n"
            if !fm.fileExists(atPath: fileURL.path) {
                text = MeasureCSV.header + "\n" + text
                guard fm.createFile(atPath: fileURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            pending.removeAll()
        } catch {
            Self.log.error("measure csv write failed code \((error as NSError).code, privacy: .public)")
            pending.removeAll()
        }
    }
}

/// Answers the iPhone's encrypted `0x7E` probes (TP1 measurement, Debug builds only).
///
/// - Every packet is opened with the connection's `measureP2M` opener; a packet that does not verify is counted and dropped.
///   Nothing is read from, or written to, the Mac unless measurement mode is on and the phone is authenticated.
/// - `rtt` probes are answered with a sealed `measureM2P` reply, but only while no earlier reply is still unanswered,
///   so the Mac's own reply queue cannot inflate the round trip. A skipped probe is counted, not answered.
/// - `cursor` probes move the test cursor by `dx × 4` and light the corner window, unless `dx` is 0 (M7 and M8 send timing
///   traffic only, which injects nothing); `heartbeat` probes only feed the
///   watchdog recorder, which counts gaps that the real 350 ms watchdog would have released a button on (模擬誤釋放) and never injects;
///   `burst` probes are only counted.
/// - The reply sealer belongs to the connection's `ChannelSet`, not to this object's mode: switching the mode off and on
///   goes on with the same counter.
///
/// Logs and the CSV hold sequence numbers, sizes and times, never a cursor position, a `dx` or any typed text.
@MainActor
final class MeasurementEcho: ObservableObject {
    struct Counters: Equatable {
        var received = 0
        var echoed = 0
        var skippedBusy = 0
        var writeRefused = 0
        var rejected = 0
        var malformed = 0
        var ignoredModeOff = 0
        var ignoredUnauthenticated = 0
        var simulatedRelease = 0
        var longTextMatched = 0
        var longTextMismatched = 0
        var maxHeartbeatGapMicros: UInt64 = 0
    }

    /// The test cursor moves this many times the finger's distance, so the first movement is easy to see on video.
    static let cursorGain = 4.0
    /// The real watchdog's limit (spec §10), only recorded here.
    static let watchdogMicros: UInt64 = 350_000
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard.receiver", category: "measure")

    @Published private(set) var isMeasureMode = false
    @Published private(set) var counters = Counters()
    /// Fires when `isMeasureMode` changes, so the status the keyboard reads can follow.
    var onModeChange: (() -> Void)?

    private let write: @MainActor (Data) -> Bool
    private let clock: @MainActor () -> UInt64
    private let cursor: MeasureCursorMoving
    private let flash: MeasureFlashing
    private let csv: MeasureCSVSink
    private let noteActivity: @MainActor () -> Void

    private var channels: ChannelSet?
    private var writeInFlight = false
    private var lastCounter: UInt64?
    private var lastArrival: UInt64?
    private var lastHeartbeatArrival: UInt64?
    private var lastHeartbeatSeq: UInt32?

    /// - Parameters:
    ///   - write: writes one sealed reply to the keyboard's `control` characteristic; `false` when no write was issued.
    ///   - clock: monotonic microseconds.
    ///   - noteActivity: called for every probe that verified, to keep the receiving session from timing out mid-run.
    init(
        write: @escaping @MainActor (Data) -> Bool, clock: @escaping @MainActor () -> UInt64 = { MeasureClock.nowMicros() },
        cursor: MeasureCursorMoving, flash: MeasureFlashing, csv: MeasureCSVSink, noteActivity: @escaping @MainActor () -> Void
    ) {
        self.write = write
        self.clock = clock
        self.cursor = cursor
        self.flash = flash
        self.csv = csv
        self.noteActivity = noteActivity
    }

    /// Hooks this echo to the central's `0x7E` route and write answers, and to the channel set of each authenticated connection.
    func connect(central: ReceiverBLECentral, security: ReceiverSecurity) {
        central.measureHandler = { [weak self] in self?.handle($0) }
        central.onMeasureWriteCompleted = { [weak self] in self?.writeCompleted() }
        security.onChannelSet = { [weak self] channels in
            if let channels { self?.attach(channels) } else { self?.detach() }
        }
    }

    /// One line for the menu panel: counts only.
    var summary: String {
        guard isMeasureMode else { return "量測模式關閉" }
        let c = counters
        return "收 \(c.received)  回 \(c.echoed)  略過 \(c.skippedBusy)  拒收 \(c.rejected)  模擬誤釋放 \(c.simulatedRelease)"
    }

    // MARK: Mode and connection

    func setMeasureMode(_ on: Bool) {
        guard on != isMeasureMode else { return }
        isMeasureMode = on
        flash.setActive(on)
        if on {
            counters = Counters()
            resetRun()
        } else {
            logRunEnd()
            csv.flush()
        }
        onModeChange?()
    }

    /// A new authenticated connection: its channel set, with counters of its own.
    func attach(_ channels: ChannelSet) {
        self.channels = channels
        writeInFlight = false
        resetRun()
    }

    /// The connection ended.
    func detach() {
        if channels != nil { logRunEnd() }
        channels = nil
        writeInFlight = false
        csv.flush()
    }

    /// The numbers of the run, for `log show` (counts and microseconds only).
    private func logRunEnd() {
        let c = counters
        guard c.received > 0 || c.rejected > 0 else { return }
        Self.log.info("""
            measure run end received=\(c.received, privacy: .public) echoed=\(c.echoed, privacy: .public) \
            skippedBusy=\(c.skippedBusy, privacy: .public) writeRefused=\(c.writeRefused, privacy: .public) \
            rejected=\(c.rejected, privacy: .public) malformed=\(c.malformed, privacy: .public) \
            simulatedRelease=\(c.simulatedRelease, privacy: .public) maxHeartbeatGapMicros=\(c.maxHeartbeatGapMicros, privacy: .public) \
            longTextMatched=\(c.longTextMatched, privacy: .public) longTextMismatched=\(c.longTextMismatched, privacy: .public)
            """)
    }

    /// The answer to the reply that `write` issued.
    func writeCompleted() { writeInFlight = false }

    private func resetRun() {
        lastCounter = nil
        lastArrival = nil
        lastHeartbeatArrival = nil
        lastHeartbeatSeq = nil
    }

    // MARK: Probes

    func handle(_ packet: Data) {
        let arrival = clock()
        guard isMeasureMode else {
            counters.ignoredModeOff += 1
            return
        }
        guard let channels else {
            counters.ignoredUnauthenticated += 1
            return
        }
        let opener = channels.opener(.measureP2M)
        let plain: Data
        switch opener.open(packet) {
        case .failure(let error):
            counters.rejected += 1
            Self.log.info("measure packet rejected \(String(describing: error), privacy: .public) bytes=\(packet.count, privacy: .public)")
            return
        case .success(let data):
            plain = data
        }
        guard let payload = MeasurePayload.decode(plain) else {
            counters.malformed += 1
            return
        }
        noteActivity()
        counters.received += 1
        // Every run starts with seq 1, whatever it sends first: the heartbeats of an earlier run are not part of this one.
        if payload.seq == 1 {
            lastHeartbeatArrival = nil
            lastHeartbeatSeq = nil
        }

        let counter = opener.lastOpenedCounter
        let gap = lastCounter.map { Int(truncatingIfNeeded: counter) - Int(truncatingIfNeeded: $0) - 1 } ?? 0
        lastCounter = max(counter, lastCounter ?? 0)
        let interArrival = lastArrival.map { Int(truncatingIfNeeded: arrival &- $0) } ?? 0
        lastArrival = arrival

        var hold = 0
        switch payload.kind {
        case .burst:
            break
        case .rtt:
            hold = reply(to: payload, arrival: arrival)
        case .cursor:
            // T5: the mouse event and the corner window go out together. A packet without a distance is timing traffic
            // (M7, M8): no mouse event and no flash.
            if payload.dxSixteenths != 0 {
                cursor.move(byPoints: Double(payload.dxSixteenths) / 16 * Self.cursorGain)
                flash.flash()
            }
        case .heartbeat:
            recordHeartbeat(payload, arrival: arrival)
        }
        csv.append(MeasureCSV.line(
            seq: payload.seq, kind: payload.kind, bytes: packet.count, counterGap: gap, interArrivalMicros: interArrival,
            holdMicros: hold, phoneTimeMicros: payload.phoneTimeMicros, macTimeMicros: arrival))
    }

    /// A text event arrived from the keyboard (M7): if it is long enough to be the measurement's long text, its length and
    /// SHA-256 are compared with it and only the verdict is kept. The text is read here and goes nowhere else.
    func noteText(_ text: String) {
        guard isMeasureMode, MeasureLongText.isCandidate(text) else { return }
        let arrival = clock()
        let check = MeasureLongText.check(text)
        if check == .match { counters.longTextMatched += 1 } else { counters.longTextMismatched += 1 }
        csv.append(MeasureCSV.longTextLine(check: check, utf8Length: text.utf8.count, macTimeMicros: arrival))
    }

    /// Returns the hold time in microseconds, or -1 when no reply was written.
    private func reply(to payload: MeasurePayload, arrival: UInt64) -> Int {
        guard !writeInFlight else {
            counters.skippedBusy += 1
            return -1
        }
        guard let channels else { return -1 }
        let held = UInt32(clamping: clock() &- arrival)
        let echo = MeasureEchoPayload(
            seq: payload.seq, phoneTimeMicros: payload.phoneTimeMicros, macHoldMicros: held, macTimeMicros: arrival)
        guard let sealed = try? channels.sealer(.measureM2P).seal(echo.encode()) else { return -1 }
        guard write(sealed) else {
            // The ciphertext is discarded; the next reply is sealed with the next counter.
            counters.writeRefused += 1
            return -1
        }
        writeInFlight = true
        counters.echoed += 1
        return Int(held)
    }

    /// M6: a heartbeat series starts at seq 1, and a seq that does not go up also starts a new one (the run was restarted).
    /// A gap above the watchdog's limit inside a series is a release the real watchdog would have made (a 模擬誤釋放);
    /// nothing is released here.
    private func recordHeartbeat(_ payload: MeasurePayload, arrival: UInt64) {
        let continuesSeries = payload.seq != 1 && (lastHeartbeatSeq.map { payload.seq > $0 } ?? false)
        if continuesSeries, let last = lastHeartbeatArrival {
            let gap = arrival &- last
            counters.maxHeartbeatGapMicros = max(counters.maxHeartbeatGapMicros, gap)
            if gap > Self.watchdogMicros { counters.simulatedRelease += 1 }
        }
        lastHeartbeatArrival = arrival
        lastHeartbeatSeq = payload.seq
    }
}
#endif
