public enum PeripheralPower: Sendable {
    case unknown, poweredOff, unauthorized, unsupported, poweredOn
}

public enum AdvertisingGate {
    public static func shouldAdvertise(power: PeripheralPower, serviceAdded: Bool) -> Bool {
        power == .poweredOn && serviceAdded
    }
}
