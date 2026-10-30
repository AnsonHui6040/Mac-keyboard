/// Decides what the keyboard does with the handwriting model, from the stamps of the App Group copy (written by the
/// host app after each finished copy) and of the copy the keyboard imported. Pure, so the table can be tested.
public enum ModelImportPolicy {
    public enum Action: Equatable, Sendable {
        /// The keyboard's own model is current; use it.
        case useLocal
        /// Copy the App Group model into the keyboard.
        case importFromGroup
        /// The host app deleted its model: remove the keyboard's copy that came from it.
        case dropLocal
        /// No model to use; the keyboard asks the user to download it in the app.
        case missing
    }

    /// What the keyboard could tell about the App Group copy. Only `.absent` means the host app deleted it; a copy that
    /// cannot be read right now (container unavailable) or is being written (no finished marker yet) says nothing.
    public enum GroupCopy: Equatable, Sendable {
        /// The container is readable and has no handwriting model folder.
        case absent
        /// The container could not be reached.
        case unavailable
        /// The folder exists without a readable finished marker (the host app is still copying, or it is unreadable).
        case exporting
        case complete(stamp: String)
    }

    /// - Parameters:
    ///   - modelPresent: ML Kit reports the model as downloaded in the keyboard's container.
    ///   - group: what is known about the App Group copy.
    ///   - localStamp: stamp recorded when the keyboard imported its copy, nil when it never imported one.
    ///   - failedStamp: the group stamp an earlier import failed for; nothing is copied again until the stamp changes.
    public static func decide(
        modelPresent: Bool, group: GroupCopy, localStamp: String?, failedStamp: String?
    ) -> Action {
        switch group {
        case .absent:
            guard modelPresent else { return .missing }
            return localStamp != nil ? .dropLocal : .useLocal
        case .unavailable, .exporting:
            return modelPresent ? .useLocal : .missing
        case .complete(let stamp):
            if modelPresent, localStamp == stamp { return .useLocal }
            if failedStamp == stamp { return modelPresent ? .useLocal : .missing }
            return .importFromGroup
        }
    }
}

/// ML Kit names its file-group metadata `<bundle id>.<group name>.<stamp>`, so a copy made by the host app has to be
/// renamed to the keyboard's bundle id before ML Kit finds it there.
public enum ModelFileNaming {
    /// `host.rest` becomes `own.rest`. Names already carrying `own.` and unrelated names stay as they are.
    public static func rekey(_ name: String, from host: String, to own: String) -> String {
        guard host != own, name.hasPrefix(host + "."), !name.hasPrefix(own + ".") else { return name }
        return own + String(name.dropFirst(host.count))
    }
}
