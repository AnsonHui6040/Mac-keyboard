#if DEBUG
import CoreBluetooth
import Network
import SwiftUI
import UIKit

/// One SNTP sample: `offset = ntp_time - local_time` in seconds, `rtt` is the network round trip in seconds.
struct NTPSample: Sendable {
    let offset: Double
    let rtt: Double
}

/// A tiny SNTP client (RFC 4330) over UDP. One instance performs one query.
final class SNTPQuery: @unchecked Sendable {
    private static let ntpToUnixEpoch = 2_208_988_800.0
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "advert-probe.sntp")
    private let connection = NWConnection(host: "time.apple.com", port: 123, using: .udp)
    private var continuation: CheckedContinuation<NTPSample?, Never>?
    private var finished = false
    private var t0 = 0.0

    func run(timeout: TimeInterval = 3) async -> NTPSample? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NTPSample?, Never>) in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready: send()
                case .failed: finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { [self] in finish(nil) }
        }
    }

    private func send() {
        connection.receiveMessage { [self] data, _, _, error in
            let t3 = Date().timeIntervalSince1970
            guard error == nil, let data else { return finish(nil) }
            finish(parse(Array(data), t3: t3))
        }
        var packet = [UInt8](repeating: 0, count: 48)
        packet[0] = 0x1B
        lock.lock()
        t0 = Date().timeIntervalSince1970
        lock.unlock()
        connection.send(content: Data(packet), completion: .contentProcessed { [self] error in
            if error != nil { finish(nil) }
        })
    }

    private func timestamp(_ bytes: [UInt8], at index: Int) -> Double {
        func word(_ offset: Int) -> UInt32 {
            bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
        }
        return Double(word(index)) - Self.ntpToUnixEpoch + Double(word(index + 4)) / 4_294_967_296.0
    }

    private func parse(_ bytes: [UInt8], t3: Double) -> NTPSample? {
        guard bytes.count >= 48, bytes[1] != 0, bytes[40..<48].contains(where: { $0 != 0 }) else { return nil }
        lock.lock()
        let t0 = t0
        lock.unlock()
        let t1 = timestamp(bytes, at: 32)
        let t2 = timestamp(bytes, at: 40)
        return NTPSample(offset: ((t1 - t0) + (t2 - t3)) / 2, rtt: (t3 - t0) - (t2 - t1))
    }

    private func finish(_ sample: NTPSample?) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        lock.unlock()
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation.resume(returning: sample)
    }

    /// Three samples, the one with the smallest round trip wins. Nil when all three fail.
    static func measure() async -> NTPSample? {
        var best: NTPSample?
        for _ in 0..<3 {
            if Task.isCancelled { break }
            if let sample = await SNTPQuery().run(), best == nil || sample.rtt < best!.rtt { best = sample }
        }
        return best
    }
}

/// Debug-only measurement tool (S8): alternates the advertised service UUID so the speed at which Windows, Linux and macOS
/// scanners notice the change can be timed. The automatic run writes `advert-probe.log` with local and NTP-corrected
/// timestamps. Never shipped.
@MainActor
final class AdvertProbe: NSObject, ObservableObject {
    struct Entry: Identifiable {
        let id: Int
        let text: String
    }

    static let uuidA = CBUUID(string: "11111111-2222-4333-8444-555555555555")
    static let uuidB = CBUUID(string: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")
    static let autoRunArgument = "-rkAdvertProbeAuto"
    static let switchesPerRun = 20
    /// True when the process was launched with `-rkAdvertProbeAuto`.
    static let launchedForAutoRun = ProcessInfo.processInfo.arguments.contains(autoRunArgument)

    @Published private(set) var stateText = "藍牙初始化中"
    @Published private(set) var isPoweredOn = false
    @Published private(set) var current: String?
    @Published private(set) var switchCount = 0
    @Published private(set) var log: [Entry] = []
    @Published private(set) var isRunning = false
    @Published private(set) var runStatus: String?
    @Published private(set) var copied = false

    private var manager: CBPeripheralManager?
    private var currentIsA = true
    private var logID = 0
    private var lines: [String] = []
    private var fileHandle: FileHandle?
    private var runTask: Task<Void, Never>?
    private var endReason = "cancelled"
    private var offset: Double?
    private var autoPending = AdvertProbe.launchedForAutoRun

    private static let isoFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSxxx"
        return formatter
    }()

    static var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("advert-probe.log")
    }

    var currentUUIDText: String? {
        guard let current else { return nil }
        return current == "A" ? Self.uuidA.uuidString : Self.uuidB.uuidString
    }

    func prepare() {
        guard manager == nil else { return }
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    // MARK: Manual control

    func startA() {
        guard isPoweredOn, !isRunning else { return }
        currentIsA = true
        advertise()
    }

    func toggle() {
        guard isPoweredOn, current != nil, !isRunning else { return }
        currentIsA.toggle()
        advertise()
    }

    func stop() {
        if isRunning {
            cancelRun(reason: "cancelled")
            return
        }
        stopAdvertising()
    }

    private func stopAdvertising() {
        manager?.stopAdvertising()
        if current != nil { append("# 已停止廣播") }
        current = nil
    }

    // MARK: Automatic run

    func startAutoRun() {
        guard !isRunning else { return }
        isRunning = true
        endReason = "done"
        runTask = Task { [weak self] in
            await self?.performRun()
        }
    }

    func cancelRun(reason: String) {
        guard isRunning else { return }
        endReason = reason
        runTask?.cancel()
    }

    func handleBackground() {
        cancelRun(reason: "cancelled")
    }

    private func performRun() async {
        beginLog()
        runStatus = "量測時鐘偏差中"
        let sample = await SNTPQuery.measure()
        offset = sample?.offset
        if let sample {
            let rtt = String(format: "%.0f", sample.rtt * 1000)
            emit("# ntp_offset_s\t\(String(format: "%+.4f", sample.offset))\trtt_ms\t\(rtt)")
        } else {
            emit("# ntp_offset_s\tunknown\trtt_ms\tNA")
        }
        if !Task.isCancelled {
            if isPoweredOn {
                await runSwitches()
            } else {
                endReason = "bluetooth_off"
            }
        }
        manager?.stopAdvertising()
        current = nil
        emit("# run_end\t\(endReason)")
        closeLog()
        runStatus = nil
        isRunning = false
        runTask = nil
    }

    private func runSwitches() async {
        let clock = ContinuousClock()
        currentIsA = true
        switchCount = 0
        advertise()
        let base = clock.now
        do {
            for index in 1...Self.switchesPerRun {
                runStatus = "第 \(index - 1)／\(Self.switchesPerRun) 次，下一次切換等待中"
                try await Task.sleep(until: base + .seconds(8 + 6 * (index - 1)), clock: clock)
                currentIsA.toggle()
                advertise()
                runStatus = "第 \(index)／\(Self.switchesPerRun) 次"
            }
            runStatus = "最後一次已送出，收尾等待中"
            try await Task.sleep(until: base + .seconds(8 + 6 * Self.switchesPerRun), clock: clock)
        } catch {
            // Cancelled: endReason was set by whoever cancelled.
        }
    }

    // MARK: Advertising and log

    private func advertise() {
        guard let manager else { return }
        manager.stopAdvertising()
        let letter = currentIsA ? "A" : "B"
        let uuid = currentIsA ? Self.uuidA : Self.uuidB
        let local = Date().timeIntervalSince1970
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [uuid]])
        emit("SWITCH\t\(switchCount)\t\(letter)\t\(stamps(local))")
        switchCount += 1
        current = letter
    }

    private func stamps(_ local: Double) -> String {
        let corrected = offset.map { String(format: "%.3f", local + $0) } ?? "NA"
        return "\(String(format: "%.3f", local))\t\(corrected)"
    }

    private func beginLog() {
        lines = []
        log = []
        logID = 0
        let url = Self.logURL
        FileManager.default.createFile(atPath: url.path, contents: nil)
        fileHandle = try? FileHandle(forWritingTo: url)
        emit("# run_start\t\(Self.isoFormatter.string(from: Date()))")
    }

    private func closeLog() {
        try? fileHandle?.close()
        fileHandle = nil
    }

    /// One log line: on screen, in the copy buffer, and (during a run) appended to the file and flushed.
    private func emit(_ text: String) {
        append(text)
        guard let fileHandle, let data = (text + "\n").data(using: .utf8) else { return }
        try? fileHandle.write(contentsOf: data)
        try? fileHandle.synchronize()
    }

    private func append(_ text: String) {
        logID += 1
        log.append(Entry(id: logID, text: text))
        lines.append(text)
    }

    func copyLog() {
        UIPasteboard.general.string = lines.joined(separator: "\n") + "\n"
        copied = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            self?.copied = false
        }
    }

    private func describe(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: "藍牙已開啟"
        case .poweredOff: "藍牙已關閉"
        case .unauthorized: "未允許使用藍牙"
        case .unsupported: "此裝置不支援藍牙"
        case .resetting: "藍牙重置中"
        default: "藍牙狀態未知"
        }
    }
}

extension AdvertProbe: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        isPoweredOn = peripheral.state == .poweredOn
        stateText = describe(peripheral.state)
        if !isPoweredOn {
            current = nil
            cancelRun(reason: "bluetooth_off")
        }
        // Launched with -rkAdvertProbeAuto: start as soon as the state is known (a run without Bluetooth ends as bluetooth_off).
        if autoPending, peripheral.state != .unknown, peripheral.state != .resetting {
            autoPending = false
            startAutoRun()
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        let n = max(switchCount - 1, 0)
        if let error {
            emit("ERROR\t\(n)\t\(error.localizedDescription)")
        } else {
            emit("CONFIRM\t\(n)\t\(stamps(Date().timeIntervalSince1970))")
        }
    }
}

struct AdvertProbeView: View {
    @StateObject private var probe = AdvertProbe()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section("狀態") {
                Text(probe.stateText)
                if let letter = probe.current, let uuid = probe.currentUUIDText {
                    Text("廣播中：\(letter)")
                    Text(uuid).font(.footnote.monospaced())
                } else {
                    Text("未廣播").foregroundStyle(.secondary)
                }
                Text("切換次數：\(probe.switchCount)")
                if let status = probe.runStatus {
                    Text(status).foregroundStyle(.secondary)
                }
            }
            Section {
                if probe.isRunning {
                    Button("取消", role: .destructive) { probe.cancelRun(reason: "cancelled") }
                } else {
                    Button("自動測試（20 次）") { probe.startAutoRun() }
                        .disabled(!probe.isPoweredOn)
                }
                Button(probe.copied ? "已複製" : "複製紀錄") { probe.copyLog() }
                    .disabled(probe.log.isEmpty)
            }
            Section("手動") {
                Button("開始廣播 A") { probe.startA() }
                    .disabled(!probe.isPoweredOn || probe.isRunning)
                Button("切換") { probe.toggle() }
                    .disabled(!probe.isPoweredOn || probe.current == nil || probe.isRunning)
                Button("停止", role: .destructive) { probe.stop() }
                    .disabled(probe.current == nil)
            }
            Section("紀錄") {
                ForEach(probe.log.reversed()) { entry in
                    Text(entry.text).font(.footnote.monospaced())
                }
            }
        }
        .navigationTitle("廣播測試")
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            probe.prepare()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            probe.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { probe.handleBackground() }
        }
    }
}
#endif
