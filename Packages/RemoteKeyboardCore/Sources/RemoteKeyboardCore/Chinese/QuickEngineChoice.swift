/// Which engine types Quick (速成).
public enum QuickEngine: String, Sendable {
    case rime
    case swift
}

public enum QuickEngineChoice {
    /// `override` is a DEBUG-only setting; only `"swift"` means anything. A started librime runtime is what decides
    /// between the two otherwise, and no override can force an engine that failed to start.
    public static func decide(override: String?, rimeStarted: Bool) -> QuickEngine {
        if override == "swift" { return .swift }
        return rimeStarted ? .rime : .swift
    }
}
