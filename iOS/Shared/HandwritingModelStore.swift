import Foundation
import RemoteKeyboardCore
import os

/// Moves ML Kit's handwriting model between the host app and the keyboard extension. File operations only: this file
/// does not import ML Kit, so both targets compile it, with or without the pod.
///
/// ML Kit keeps a downloaded model in the calling process's own `Library/Application Support/<directoryName>`. The
/// extension cannot download it (the download never progressed there), so the host app downloads, then copies that
/// directory into the App Group (`HandwritingModels/`), and the extension copies it into its own container.
///
/// ML Kit names its file-group metadata `<bundle id>.<group name>.<stamp>`. The host app's id is
/// `com.ansonhui.remotekeyboard` and the extension's `com.ansonhui.remotekeyboard.keyboard`, so the import renames
/// those files to the extension's id (`ModelFileNaming.rekey`); without that ML Kit does not find the model.
///
/// Stamps: the host app writes a fresh stamp into the group's `.complete` marker as the very last step of an export
/// (the marker is removed first). The import copies into a staging directory beside ML Kit's, records the group stamp
/// swaps the staging directory in with one `replaceItemAt`, so ML Kit never sees a half-copied directory, and then
/// records the group stamp in a marker file beside ML Kit's directory. Logs carry sizes, counts and durations only.
enum HandwritingModelStore {
    /// The language of the model (ML Kit has no separate Hant model; `zh-Hani` covers Traditional and Simplified).
    static let languageTag = "zh-Hani-TW"
    /// ML Kit's storage directory name inside Application Support.
    static let mlKitDirectoryName = "com.google.mlkit.vision.digitalinkrecognition"

    private static let groupFolderName = "HandwritingModels"
    /// Written last by the export and holding the copy's stamp, so a half-finished copy is never imported.
    private static let completeMarkerName = ".complete"
    /// Written beside the keyboard's ML Kit directory (not inside it) after the swap; holds the stamp of the group
    /// copy the keyboard's model came from.
    private static let importedMarkerName = ".handwriting-imported-stamp"
    private static let stagingPrefix = ".handwriting-import-"
    private static let logger = Logger(subsystem: "com.ansonhui.remotekeyboard", category: "handwriting")

    struct Summary: Equatable, Sendable {
        var bytes: Int64
        var files: Int
        var renamed: Int
        var seconds: Double
    }

    enum StoreError: Error, Equatable, CustomStringConvertible {
        case noGroup
        case nothingToCopy
        /// The task was cancelled; nothing was changed.
        case cancelled
        case failed(String)

        var description: String {
            switch self {
            case .noGroup: "App Group 無法使用"
            case .nothingToCopy: "找不到已下載的手寫模型"
            case .cancelled: "已取消"
            case .failed(let reason): reason
            }
        }
    }

    // MARK: Locations

    /// ML Kit's storage directory of the current process (host app or extension).
    static var localDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(mlKitDirectoryName, isDirectory: true)
    }

    private static var groupRoot: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier)?
            .appendingPathComponent(groupFolderName, isDirectory: true)
    }

    private static var groupDirectory: URL? {
        groupRoot?.appendingPathComponent(mlKitDirectoryName, isDirectory: true)
    }

    // MARK: Queries

    /// What is known about the App Group copy. Only `.absent` means the host app has no copy; an unreachable container
    /// or a folder without a readable finished marker (the host app is copying) must not be mistaken for that.
    static func groupCopyState() -> ModelImportPolicy.GroupCopy {
        guard let root = groupRoot else { return .unavailable }
        guard FileManager.default.fileExists(atPath: root.path) else { return .absent }
        guard let stamp = readStamp(at: root.appendingPathComponent(completeMarkerName)) else { return .exporting }
        return .complete(stamp: stamp)
    }

    /// True when the App Group holds a finished copy of the model.
    static func groupCopyIsComplete() -> Bool { groupStamp() != nil }

    /// Stamp of the finished App Group copy, nil when there is none (see `groupCopyState` for why).
    static func groupStamp() -> String? {
        if case .complete(let stamp) = groupCopyState() { return stamp }
        return nil
    }

    /// Stamp of the group copy this process's ML Kit directory was imported from, nil when it was not imported.
    static func localStamp() -> String? {
        readStamp(at: importedMarkerURL)
    }

    private static var importedMarkerURL: URL {
        localDirectory.deletingLastPathComponent().appendingPathComponent(importedMarkerName)
    }

    private static func readStamp(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        return text
    }

    /// Size of the finished copy in the App Group, nil when there is none.
    static func groupCopySize() -> Int64? {
        guard groupCopyIsComplete(), let directory = groupDirectory else { return nil }
        return size(of: directory).bytes
    }

    static func size(of directory: URL) -> (bytes: Int64, files: Int) {
        guard let walker = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return (0, 0) }
        var bytes: Int64 = 0
        var files = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            bytes += Int64(values?.fileSize ?? 0)
            files += 1
        }
        return (bytes, files)
    }

    // MARK: Host app

    /// Replaces the App Group copy with this process's ML Kit directory.
    static func exportToGroup() throws -> Summary {
        guard let root = groupRoot, let destination = groupDirectory else { throw StoreError.noGroup }
        let source = localDirectory
        guard FileManager.default.fileExists(atPath: source.path) else { throw StoreError.nothingToCopy }
        let start = Date()
        // The folder stays while the copy is rewritten, so the keyboard sees "exporting", never "absent".
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try? manager.removeItem(at: root.appendingPathComponent(completeMarkerName))
        ImmutableFiles.clearFlags(under: destination)
        try? manager.removeItem(at: destination)
        var summary = try copyTree(from: source, to: destination, rename: nil)
        guard FileManager.default.createFile(
            atPath: root.appendingPathComponent(completeMarkerName).path,
            contents: Data(UUID().uuidString.utf8)) else {
            throw StoreError.failed("無法完成複製")
        }
        summary.seconds = Date().timeIntervalSince(start)
        logger.info("model export bytes=\(summary.bytes, privacy: .public) files=\(summary.files, privacy: .public) seconds=\(summary.seconds, privacy: .public)")
        return summary
    }

    /// Removes the App Group copy. A missing copy is not an error.
    static func removeGroupCopy() {
        guard let root = groupRoot else { return }
        ImmutableFiles.clearFlags(under: root)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Keyboard extension

    /// The containing app's id: the extension sits in `<App>.app/PlugIns/<name>.appex`. Falls back to stripping `.keyboard`.
    private static func hostBundleIdentifier(own: String) -> String {
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        if let id = Bundle(url: app)?.bundleIdentifier { return id }
        return own.hasSuffix(".keyboard") ? String(own.dropLast(".keyboard".count)) : own
    }

    /// Copies the App Group copy into a staging directory beside this process's ML Kit directory, then swaps it in
    /// with one step. Honours task cancellation (the staging directory is removed) and refuses the copy when the
    /// group copy changed while it was being read.
    static func importFromGroup() throws -> Summary {
        guard let source = groupDirectory, let stamp = groupStamp() else { throw StoreError.nothingToCopy }
        let manager = FileManager.default
        let start = Date()
        let own = Bundle.main.bundleIdentifier ?? ""
        let host = hostBundleIdentifier(own: own)
        let destination = localDirectory
        let parent = destination.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        removeStaleStagingDirectories(in: parent)
        let staging = parent.appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        defer {
            ImmutableFiles.clearFlags(under: staging)
            try? manager.removeItem(at: staging)
        }

        var summary = try copyTree(from: source, to: staging, rename: { name in
            ModelFileNaming.rekey(name, from: host, to: own)
        })
        guard groupStamp() == stamp else { throw StoreError.failed("模型在複製時被更新，請稍後再試") }
        try checkNotCancelled()
        do {
            if manager.fileExists(atPath: destination.path) {
                ImmutableFiles.clearFlags(under: destination)
                _ = try manager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: destination)
            }
        } catch {
            let code = error as NSError
            throw StoreError.failed("無法換入模型（\(code.domain) \(code.code)）")
        }
        // After the swap. A crash before this line leaves an older stamp, which only makes the next start copy again.
        guard manager.createFile(atPath: importedMarkerURL.path, contents: Data(stamp.utf8)) else {
            throw StoreError.failed("無法寫入匯入記號")
        }
        summary.seconds = Date().timeIntervalSince(start)
        logger.info("model import bytes=\(summary.bytes, privacy: .public) files=\(summary.files, privacy: .public) renamed=\(summary.renamed, privacy: .public) seconds=\(summary.seconds, privacy: .public)")
        return summary
    }

    /// Removes this process's ML Kit directory (the model was dropped by the host app, or turned out to be unusable).
    static func removeLocalCopy() {
        ImmutableFiles.clearFlags(under: localDirectory)
        try? FileManager.default.removeItem(at: localDirectory)
        try? FileManager.default.removeItem(at: importedMarkerURL)
    }

    private static func removeStaleStagingDirectories(in parent: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names where name.hasPrefix(stagingPrefix) {
            let stale = parent.appendingPathComponent(name)
            ImmutableFiles.clearFlags(under: stale)
            try? FileManager.default.removeItem(at: stale)
        }
    }

    private static func checkNotCancelled() throws {
        if Task.isCancelled { throw StoreError.cancelled }
    }

    // MARK: Copy

    private static func copyTree(from source: URL, to destination: URL, rename: ((String) -> String)?) throws -> Summary {
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        var summary = Summary(bytes: 0, files: 0, renamed: 0, seconds: 0)
        let basePath = source.standardizedFileURL.path
        guard let walker = manager.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else {
            throw StoreError.failed("無法讀取模型資料夾")
        }
        for case let url as URL in walker {
            try checkNotCancelled()
            var relative = String(url.standardizedFileURL.path.dropFirst(basePath.count))
            if relative.hasPrefix("/") { relative.removeFirst() }
            var parts = relative.split(separator: "/").map(String.init)
            if let rename, let last = parts.last {
                let renamed = rename(last)
                if renamed != last { summary.renamed += 1 }
                parts[parts.count - 1] = renamed
            }
            let target = parts.reduce(destination) { $0.appendingPathComponent($1) }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            do {
                if values.isDirectory == true {
                    try manager.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    ImmutableFiles.clearFlags(under: target)
                    try? manager.removeItem(at: target)
                    try manager.copyItem(at: url, to: target)
                    ImmutableFiles.clearFlags(under: target)
                    summary.bytes += Int64(values.fileSize ?? 0)
                    summary.files += 1
                }
            } catch {
                let code = error as NSError
                throw StoreError.failed("複製失敗（\(code.domain) \(code.code)）")
            }
        }
        return summary
    }
}
