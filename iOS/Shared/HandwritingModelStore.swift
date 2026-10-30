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
/// those files to the extension's id; without that ML Kit does not find the model. Logs carry sizes, counts and
/// durations only.
enum HandwritingModelStore {
    /// The language of the model (ML Kit has no separate Hant model; `zh-Hani` covers Traditional and Simplified).
    static let languageTag = "zh-Hani-TW"
    /// ML Kit's storage directory name inside Application Support.
    static let mlKitDirectoryName = "com.google.mlkit.vision.digitalinkrecognition"

    private static let groupFolderName = "HandwritingModels"
    /// Written after the copy into the group finished, so a half-finished copy is never imported.
    private static let completeMarkerName = ".complete"
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
        case failed(String)

        var description: String {
            switch self {
            case .noGroup: "App Group 無法使用"
            case .nothingToCopy: "找不到已下載的手寫模型"
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

    /// True when the App Group holds a finished copy of the model.
    static func groupCopyIsComplete() -> Bool {
        guard let root = groupRoot else { return false }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent(completeMarkerName).path)
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
        try? FileManager.default.removeItem(at: root)
        var summary = try copyTree(from: source, to: destination, rename: nil)
        guard FileManager.default.createFile(
            atPath: root.appendingPathComponent(completeMarkerName).path, contents: Data()) else {
            throw StoreError.failed("無法完成複製")
        }
        summary.seconds = Date().timeIntervalSince(start)
        logger.info("model export bytes=\(summary.bytes, privacy: .public) files=\(summary.files, privacy: .public) seconds=\(summary.seconds, privacy: .public)")
        return summary
    }

    /// Removes the App Group copy. A missing copy is not an error.
    static func removeGroupCopy() {
        guard let root = groupRoot else { return }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Keyboard extension

    /// Copies the App Group copy over this process's ML Kit directory. Top-level items are replaced, so a half-finished
    /// earlier copy is overwritten. Metadata file names are re-keyed from the host app's bundle id to this process's.
    static func importFromGroup() throws -> Summary {
        guard let source = groupDirectory else { throw StoreError.noGroup }
        guard groupCopyIsComplete() else { throw StoreError.nothingToCopy }
        let start = Date()
        let own = Bundle.main.bundleIdentifier ?? ""
        let host = own.hasSuffix(".keyboard") ? String(own.dropLast(".keyboard".count)) : own
        let destination = localDirectory
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
            try? FileManager.default.removeItem(at: destination.appendingPathComponent(item.lastPathComponent))
        }
        var summary = try copyTree(from: source, to: destination, rename: { name in
            rekey(name, from: host, to: own)
        })
        summary.seconds = Date().timeIntervalSince(start)
        logger.info("model import bytes=\(summary.bytes, privacy: .public) files=\(summary.files, privacy: .public) renamed=\(summary.renamed, privacy: .public) seconds=\(summary.seconds, privacy: .public)")
        return summary
    }

    /// `host.rest` becomes `own.rest`. Names already carrying `own.` and unrelated names stay as they are.
    static func rekey(_ name: String, from host: String, to own: String) -> String {
        guard host != own, name.hasPrefix(host + "."), !name.hasPrefix(own + ".") else { return name }
        return own + String(name.dropFirst(host.count))
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
                    try? manager.removeItem(at: target)
                    try manager.copyItem(at: url, to: target)
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
