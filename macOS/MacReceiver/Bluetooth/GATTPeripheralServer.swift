import CoreBluetooth
import Foundation
import RemoteKeyboardCore

/// Published to the menu bar. `failed` carries an error code only, never typed text.
enum GATTServerState: Equatable {
    case idle
    case waitingForPower
    case addingService
    case advertising
    case failed(String)

    var label: String {
        switch self {
        case .idle: "idle"
        case .waitingForPower: "waiting for Bluetooth"
        case .addingService: "adding service"
        case .advertising: "advertising"
        case .failed(let code): "failed (\(code))"
        }
    }
}

/// Seam over `CBPeripheralManager` so lifecycle logic can be tested without hardware.
@MainActor
protocol PeripheralManaging: AnyObject {
    func add(_ service: CBMutableService)
    func removeAllServices()
    func startAdvertising(_ advertisementData: [String: Any]?)
    func stopAdvertising()
}

extension CBPeripheralManager: @MainActor PeripheralManaging {}

@MainActor
final class GATTPeripheralServer: NSObject, ObservableObject {
    @Published private(set) var state: GATTServerState = .idle

    private let makeManager: (GATTPeripheralServer) -> PeripheralManaging
    private var manager: PeripheralManaging?
    private var power: PeripheralPower = .unknown
    private var serviceAdded = false
    private var wantsRunning = false

    init(makeManager: @escaping (GATTPeripheralServer) -> PeripheralManaging = {
        CBPeripheralManager(delegate: $0, queue: nil)
    }) {
        self.makeManager = makeManager
        super.init()
    }

    static func makeService() -> CBMutableService {
        let input = CBMutableCharacteristic(
            type: CBUUID(string: GATTServiceSpec.inputUUID),
            properties: [.write],
            value: nil,
            permissions: [.writeable])
        let ack = CBMutableCharacteristic(
            type: CBUUID(string: GATTServiceSpec.ackUUID),
            properties: [.notify],
            value: nil,
            permissions: [.readable])
        let status = CBMutableCharacteristic(
            type: CBUUID(string: GATTServiceSpec.statusUUID),
            properties: [.read, .notify],
            value: nil,
            permissions: [.readable])
        let service = CBMutableService(type: CBUUID(string: GATTServiceSpec.serviceUUID), primary: true)
        service.characteristics = [input, ack, status]
        return service
    }

    func start() {
        wantsRunning = true
        if manager == nil {
            state = .waitingForPower
            manager = makeManager(self)
        } else {
            reconcile()
        }
    }

    func stop() {
        wantsRunning = false
        manager?.stopAdvertising()
        manager?.removeAllServices()
        serviceAdded = false
        state = .idle
    }

    private func reconcile() {
        guard wantsRunning, let manager else { return }
        guard power == .poweredOn else {
            serviceAdded = false
            state = .waitingForPower
            return
        }
        if !serviceAdded {
            if state != .addingService {
                state = .addingService
                manager.add(Self.makeService())
            }
        } else if AdvertisingGate.shouldAdvertise(power: power, serviceAdded: serviceAdded), state != .advertising {
            manager.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: GATTServiceSpec.serviceUUID)],
                CBAdvertisementDataLocalNameKey: "RemoteKeyboard"
            ])
        }
    }

    func handlePowerChange(_ newPower: PeripheralPower) {
        power = newPower
        reconcile()
    }

    func handleServiceAdded(error: Error?) {
        // After stop() the service was removed; a late callback must not mark it present.
        guard wantsRunning else { return }
        if let error {
            state = .failed("add-service-\((error as NSError).code)")
            return
        }
        serviceAdded = true
        reconcile()
    }

    func handleAdvertisingStarted(error: Error?) {
        guard wantsRunning else { return }
        state = error.map { .failed("advertise-\(($0 as NSError).code)") } ?? .advertising
    }
}

extension GATTPeripheralServer: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let mapped: PeripheralPower = switch peripheral.state {
        case .poweredOn: .poweredOn
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        default: .unknown
        }
        handlePowerChange(mapped)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        handleServiceAdded(error: error)
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        handleAdvertisingStarted(error: error)
    }
}
