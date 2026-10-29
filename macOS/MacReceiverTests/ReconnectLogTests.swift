import RemoteKeyboardCore
import XCTest
@testable import MacReceiver

/// Writes only under a fresh temporary directory; the real `~/Library/Logs` is never touched.
final class ReconnectLogTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "rk-reconnect-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func contents(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testCreatesMissingDirectoriesAndWritesOneLine() throws {
        let url = root.appending(path: "Logs/RemoteKeyboard/reconnect.csv")
        let log = ReconnectLog(fileURL: url)
        XCTAssertTrue(log.record(shownAtMs: 1_000, connectedAtMs: 1_480))
        XCTAssertEqual(try contents(url), "1000,1480,480\n")
    }

    func testAppendsInsteadOfOverwriting() throws {
        let url = root.appending(path: "reconnect.csv")
        let log = ReconnectLog(fileURL: url)
        log.record(shownAtMs: 10, connectedAtMs: 110)
        log.record(shownAtMs: 20, connectedAtMs: 520)
        // A second logger on the same file (an app restart) keeps what is already there.
        ReconnectLog(fileURL: url).record(shownAtMs: 30, connectedAtMs: 31)
        XCTAssertEqual(try contents(url), "10,110,100\n20,520,500\n30,31,1\n")
    }

    func testWrittenLinesParseBackIntoSamples() throws {
        let url = root.appending(path: "reconnect.csv")
        let log = ReconnectLog(fileURL: url)
        for i in 1...100 { log.record(shownAtMs: Int64(i * 1000), connectedAtMs: Int64(i * 1000 + i)) }
        let samples = ReconnectCSV.samples(from: try contents(url))
        XCTAssertEqual(ReconnectStats.summarize(samples), ReconnectSummary(attempts: 100, successes: 100, p95Ms: 95))
    }

    func testUnwritableLocationReportsFailureWithoutCrashing() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appending(path: "file")
        try Data().write(to: blocker)
        // A directory cannot be created below a regular file.
        let log = ReconnectLog(fileURL: blocker.appending(path: "sub/reconnect.csv"))
        XCTAssertFalse(log.record(shownAtMs: 1, connectedAtMs: 2))
    }

    func testDefaultLocationIsUnderLibraryLogs() {
        let path = ReconnectLog.defaultFileURL.path
        XCTAssertTrue(path.hasSuffix("/Library/Logs/RemoteKeyboard/reconnect.csv"), path)
    }
}
