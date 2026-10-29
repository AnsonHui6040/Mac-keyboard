import CoreBluetooth
import Foundation
import RemoteKeyboardCore

/// Adapter between the Core `KeyboardLinkStateMachine` and CoreBluetooth.
/// The keyboard extension advertises while visible; the Mac Receiver is the central.
@MainActor
final class KeyboardBLEPeripheral: NSObject {
    var onStateChange: ((KeyboardLinkState) -> Void)?

    private var machine = KeyboardLinkStateMachine()
    private var manager: CBPeripheralManager?
    private var eventCharacteristic: CBMutableCharacteristic?

    private static let serviceID = CBUUID(string: GATTServiceSpec.Link.serviceUUID)
    private static let eventID = CBUUID(string: GATTServiceSpec.Link.eventUUID)
    private static let controlID = CBUUID(string: GATTServiceSpec.Link.controlUUID)

    func viewWillAppear(hasFullAccess: Bool) {
        // Without Full Access no CBPeripheralManager is created at all.
        if hasFullAccess && manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: nil)
        }
        feed(.appeared(hasFullAccess: hasFullAccess))
    }

    func viewDidDisappear() {
        feed(.disappeared)
    }

    private func feed(_ input: KeyboardLinkInput) {
        let before = machine.state
        let effects = machine.handle(input)
        for effect in effects { perform(effect) }
        if machine.state != before || input == .disappeared { onStateChange?(machine.state) }
    }

    private func perform(_ effect: KeyboardLinkEffect) {
        guard let manager else { return }
        switch effect {
        case .addService:
            let event = CBMutableCharacteristic(
                type: Self.eventID, properties: [.notify], value: nil, permissions: [])
            let control = CBMutableCharacteristic(
                type: Self.controlID, properties: [.write], value: nil, permissions: [.writeable])
            let service = CBMutableService(type: Self.serviceID, primary: true)
            service.characteristics = [event, control]
            eventCharacteristic = event
            manager.add(service)
        case .startAdvertising:
            manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceID]])
        case .stopAdvertising:
            manager.stopAdvertising()
        case .removeServices:
            manager.removeAllServices()
            eventCharacteristic = nil
        }
    }

    private static func map(_ state: CBManagerState) -> PeripheralPower {
        switch state {
        case .poweredOn: .poweredOn
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        default: .unknown
        }
    }
}

extension KeyboardBLEPeripheral: @preconcurrency CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        feed(.power(Self.map(peripheral.state)))
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        feed(.serviceAdded(ok: error == nil))
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        feed(.advertisingStarted(ok: error == nil))
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == Self.eventID else { return }
        feed(.subscribed)
    }

    func peripheralManager(
        _ peripheral: CBPeripheralManager, central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        guard characteristic.uuid == Self.eventID else { return }
        feed(.unsubscribed)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // Control payloads are handled in T05; always acknowledge.
        guard let first = requests.first else { return }
        peripheral.respond(to: first, withResult: .success)
    }
}
