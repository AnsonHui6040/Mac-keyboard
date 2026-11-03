import Foundation

/// ML Kit marks its model files with the BSD immutable flag, and `copyItem` keeps it, which makes `removeItem` and
/// `replaceItemAt` fail with EPERM. Clearing the flag first lets a tree be deleted or swapped.
public enum ImmutableFiles {
    /// Clears the immutable flag on `root` and everything below it. Symlinks are skipped, never followed.
    /// Best effort: a missing root or an item that cannot be changed is ignored.
    public static func clearFlags(under root: URL) {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: root.path) else { return }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return }
        if attributes[.immutable] as? Bool == true {
            try? manager.setAttributes([.immutable: false], ofItemAtPath: root.path)
        }
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              let names = try? manager.contentsOfDirectory(atPath: root.path) else { return }
        for name in names {
            clearFlags(under: root.appendingPathComponent(name))
        }
    }
}
