import Foundation
import OSLog
import RemoteKeyboardCore

/// Appends one `shownAtMs,connectedAtMs,latencyMs` line per reconnect ping to a CSV file, no header.
/// The file is the T06 evidence: its line count is the number of successful reconnects. It holds numbers only,
/// never typed text. The URL is injected so tests write to a temporary directory.
final class ReconnectLog {
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard.receiver", category: "reconnect")

    /// `~/Library/Logs/RemoteKeyboard/reconnect.csv`.
    static var defaultFileURL: URL {
        URL.libraryDirectory.appending(path: "Logs/RemoteKeyboard/reconnect.csv", directoryHint: .notDirectory)
    }

    let fileURL: URL

    init(fileURL: URL) { self.fileURL = fileURL }

    /// Creates the directory and file when missing, then appends. Returns whether the line was written.
    @discardableResult
    func record(shownAtMs: Int64, connectedAtMs: Int64) -> Bool {
        let line = ReconnectCSV.line(shownAtMs: shownAtMs, connectedAtMs: connectedAtMs) + "\n"
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) {
                guard fm.createFile(atPath: fileURL.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            return true
        } catch {
            Self.log.error("reconnect csv write failed code \((error as NSError).code, privacy: .public)")
            return false
        }
    }
}
