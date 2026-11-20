import Foundation
import XCTest
@testable import RimeEngine

enum RimeFixtureError: Error, CustomStringConvertible {
    case deployerMissing(String)
    case deployFailed(Int32, String)
    var description: String {
        switch self {
        case .deployerMissing(let p): return "rime_deployer not found at \(p); run scripts/rime/build-xcframework.sh"
        case .deployFailed(let c, let o): return "rime_deployer exited \(c): \(o)"
        }
    }
}

/// Compiles fixture schemas once per test process (librime runs once per process).
enum RimeFixture {
    /// Source directories copied into the compiled data directory. Extend this list for more schemes.
    static let sourceDirectories: [URL] = [
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/rime")
    ]

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: RimePaths?

    static func compiled(_ name: String) throws -> RimePaths {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let fm = FileManager.default
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let deployer = repoRoot.appending(path: "build/rime/bin/rime_deployer")
        guard fm.isExecutableFile(atPath: deployer.path) else {
            throw RimeFixtureError.deployerMissing(deployer.path)
        }
        let base = fm.temporaryDirectory.appending(path: "rime-fixture-\(UUID().uuidString)")
        let shared = base.appending(path: "shared")
        let user = base.appending(path: "user")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        try fm.createDirectory(at: user, withIntermediateDirectories: true)
        for dir in sourceDirectories {
            for file in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where file.pathExtension == "yaml" {
                let dest = shared.appending(path: file.lastPathComponent)
                if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
                try fm.copyItem(at: file, to: dest)
            }
        }
        let build = shared.appending(path: "build")
        let process = Process()
        process.executableURL = deployer
        process.arguments = ["--build", shared.path, shared.path, build.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RimeFixtureError.deployFailed(process.terminationStatus, output)
        }
        let brokenTable = build.appending(path: "broken.table.bin")
        if fm.fileExists(atPath: brokenTable.path) { try fm.removeItem(at: brokenTable) }
        let paths = RimePaths(sharedData: shared, prebuilt: build, userData: user)
        cached = paths
        return paths
    }
}
