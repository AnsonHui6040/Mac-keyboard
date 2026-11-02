import XCTest
@testable import RemoteKeyboardCore

final class ImmutableFilesTests: XCTestCase {
    private var root: URL!
    private var lockedFile: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImmutableFilesTests-" + UUID().uuidString, isDirectory: true)
        let nested = root.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        lockedFile = nested.appendingPathComponent("model.bin")
        try Data("payload".utf8).write(to: lockedFile)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: lockedFile.path)
    }

    override func tearDown() {
        ImmutableFiles.clearFlags(under: root)
        try? FileManager.default.removeItem(at: root)
    }

    func testRemoveFailsWhileImmutable() {
        XCTAssertThrowsError(try FileManager.default.removeItem(at: root))
    }

    func testRemoveSucceedsAfterClearing() throws {
        ImmutableFiles.clearFlags(under: root)
        try FileManager.default.removeItem(at: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testMissingRootDoesNotCrash() {
        ImmutableFiles.clearFlags(under: root.appendingPathComponent("missing"))
    }

    func testClearingKeepsContents() throws {
        ImmutableFiles.clearFlags(under: root)
        XCTAssertEqual(try Data(contentsOf: lockedFile), Data("payload".utf8))
    }
}
