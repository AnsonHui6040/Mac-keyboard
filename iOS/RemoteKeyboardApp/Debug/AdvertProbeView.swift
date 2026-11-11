#if DEBUG
import CoreBluetooth
import SwiftUI
import UIKit

/// Debug-only measurement tool (S8): alternates the advertised service UUID so the speed at which Windows, Linux and macOS
/// scanners notice the change can be timed. Never shipped.
@MainActor
final class AdvertProbe: NSObject, ObservableObject {
    struct Entry: Identifiable {
        let id: Int
        let text: String
    }

    static let uuidA = CBUUID(string: "11111111-2222-4333-8444-555555555555")
    static let uuidB = CBUUID(string: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE")

    @Published private(set) var stateText = "藍牙初始化中"
    @Published private(set) var isPoweredOn = false
    @Published private(set) var current: String?
    @Published private(set) var switchCount = 0
    @Published private(set) var log: [Entry] = []

    private var manager: CBPeripheralManager?
    private var currentIsA = true
    private var wantsStart = false
    private var logID = 0

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var currentUUIDText: String? {
        guard let current else { return nil }
        return current == "A" ? Self.uuidA.uuidString : Self.uuidB.uuidString
    }

    func prepare() {
        guard manager == nil else { return }
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func startA() {
        guard isPoweredOn else { return }
        wantsStart = true
        currentIsA = true
        advertise()
    }

    func toggle() {
        guard isPoweredOn, current != nil else { return }
        currentIsA.toggle()
        advertise()
    }

    func stop() {
        wantsStart = false
        manager?.stopAdvertising()
        if current != nil { append("已停止廣播") }
        current = nil
    }

    private func advertise() {
        guard let manager else { return }
        manager.stopAdvertising()
        let letter = currentIsA ? "A" : "B"
        let uuid = currentIsA ? Self.uuidA : Self.uuidB
        let stamp = Self.formatter.string(from: Date())
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [uuid]])
        switchCount += 1
        current = letter
        append("#\(switchCount)  \(letter)  \(stamp)")
    }

    private func append(_ text: String) {
        logID += 1
        log.append(Entry(id: logID, text: text))
        if log.count > 40 { log.removeFirst(log.count - 40) }
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
        if !isPoweredOn { current = nil }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            append("廣播啟動失敗：\(error.localizedDescription)")
        } else {
            append("廣播已確認（\(Self.formatter.string(from: Date()))）")
        }
    }
}

struct AdvertProbeView: View {
    @StateObject private var probe = AdvertProbe()

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
            }
            Section {
                Button("開始廣播 A") { probe.startA() }
                    .disabled(!probe.isPoweredOn)
                Button("切換") { probe.toggle() }
                    .disabled(!probe.isPoweredOn || probe.current == nil)
                Button("停止", role: .destructive) { probe.stop() }
                    .disabled(probe.current == nil)
            }
            Section("紀錄（最近 40 筆）") {
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
    }
}
#endif
