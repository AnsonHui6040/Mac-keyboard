public enum KeyboardMode: String, Codable, Sendable {
    case local
    case remote
}

public enum ModeResolver {
    /// Remote needs Full Access (CoreBluetooth in the extension); without it the keyboard stays Local.
    public static func effectiveMode(saved: KeyboardMode, hasFullAccess: Bool) -> KeyboardMode {
        saved == .remote && hasFullAccess ? .remote : .local
    }

    /// Decodes the persisted raw value; anything missing or unknown is Local.
    public static func saved(rawValue: String?) -> KeyboardMode {
        rawValue.flatMap(KeyboardMode.init(rawValue:)) ?? .local
    }
}
